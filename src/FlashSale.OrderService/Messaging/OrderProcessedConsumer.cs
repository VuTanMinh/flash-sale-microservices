using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Serilog.Context;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Consumes OrderProcessed from the Process Worker (Week 11) and closes the
/// order out: Confirmed -> Completed, the transition that was an open
/// question in docs/order-state-machine.md from Week 1 until this week.
///
/// A separate class from StockResultConsumer rather than a third queue
/// bolted onto it: that consumer exists to handle Inventory Service's two
/// stock results, and this one handles a different upstream service's single
/// completion event. Keeping one consumer per upstream integration matches
/// how the rest of this system is laid out (each service owns a consumer per
/// producer it listens to) and follows the same
/// duplication-over-premature-abstraction call already made for
/// RabbitMqOptions, which exists three times on purpose.
///
/// The idempotent state transition itself is NOT duplicated -- it reuses
/// StockResultProcessor, which despite its Week 8 name is state-agnostic:
/// it takes a target state and applies it under an Inbox check, which is
/// exactly what is needed here too.
/// </summary>
public class OrderProcessedConsumer : BackgroundService
{
    // Two independent ladders, deliberately not one array.
    //
    // RetryDelays bounds how often a *failing* handler is retried in-process
    // before the message is dead-lettered (a database error, a lost
    // connection). It is 1/2/4 s because that is the schedule every other
    // consumer and OutboxPublisherWorker in this system uses, and that is what
    // docs/delivery-semantics.md and docs/outbox.md document.
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    // RequeueDelays is a different mechanism with a different job: how long an
    // OrderProcessed that arrived *before* its StockReserved waits, on a broker
    // queue, before it is tried again. It is longer than the in-process
    // schedule because the thing being waited for is another service crossing
    // the same broker (Inventory's StockReserved), not a transient local error
    // -- and it is bounded the same way, so an order whose StockReserved never
    // arrives surfaces in the DLQ instead of waiting forever. Element i is the
    // TTL of OrderProcessed.retry.{i+1}.
    private static readonly TimeSpan[] RequeueDelays =
    [
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
    ];

    // Set on every requeued copy, so it knows which retry queue to go to next
    // and when to give up. A header rather than a database column: the retry
    // state belongs to the delivery, not to the order, and the order's own
    // Inbox must stay empty until the completion is actually applied.
    private const string RetryAttemptHeader = "x-order-processed-attempts";

    /// <summary>
    /// Delayed retry queue for the copy that follows a message already requeued
    /// <paramref name="retryIndex"/> times (0 = the first arrival was requeued,
    /// so it waits <c>RequeueDelays[0]</c>).
    /// </summary>
    private static string RetryQueueName(int retryIndex) => $"OrderProcessed.retry.{retryIndex + 1}";

    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<OrderProcessedConsumer> _logger;
    private readonly IConfiguration _configuration;
    private IConnection? _connection;
    private IChannel? _channel;

    /// <summary>Publisher-confirming channel, used only by <see cref="RequeueForRetryAsync"/>.</summary>
    private IChannel? _requeueChannel;

    public OrderProcessedConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<OrderProcessedConsumer> logger,
        IConfiguration configuration)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
        _configuration = configuration;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var factory = new ConnectionFactory
        {
            HostName = _options.Connections.Default.HostName,
            Port = _options.Connections.Default.Port,
            UserName = _options.Connections.Default.UserName,
            Password = _options.Connections.Default.Password,
        };

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                _connection = await factory.CreateConnectionAsync(stoppingToken);
                _channel = await _connection.CreateChannelAsync(cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.ExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.DeadLetterExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderProcessedDeadLetterQueueName, durable: true, exclusive: false,
                    autoDelete: false, cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessedDeadLetterQueueName, _options.EventBus.DeadLetterExchangeName,
                    routingKey: "OrderProcessed", cancellationToken: stoppingToken);

                // Delayed retry queues (Week 9, out-of-order completion). An
                // OrderProcessed that arrives before the order's StockReserved
                // must be retried, not dead-lettered (docs/design-decisions.md
                // section 2), and RabbitMQ has no per-message redelivery delay,
                // so each attempt gets a queue whose whole point is a TTL: the
                // message is simply left there and dead-lettered back onto
                // flashsale.order.exchange with routing key "OrderProcessed"
                // once it expires. That is why the dead-letter routing key is
                // set explicitly here and not on the main queue: these queues
                // receive the message under a ".retry.N" key, so preserving the
                // key would dead-letter it back to a retry queue instead of the
                // main one.
                //
                // The binding to the dead-letter exchange is what makes the
                // requeue publish routable at all (RequeueForRetryAsync
                // publishes to that exchange with the queue name as its routing
                // key). Without it the publish is dropped as unroutable -- and
                // because the original is only acked after that publish is
                // *confirmed*, an unroutable copy would throw instead of
                // disappearing, but binding it here is what makes the retry
                // actually happen.
                for (var attempt = 1; attempt <= RequeueDelays.Length; attempt++)
                {
                    var retryQueue = RetryQueueName(attempt - 1);
                    await _channel.QueueDeclareAsync(
                        retryQueue, durable: true, exclusive: false, autoDelete: false,
                        arguments: new Dictionary<string, object?>
                        {
                            ["x-message-ttl"] = (int)RequeueDelays[attempt - 1].TotalMilliseconds,
                            ["x-dead-letter-exchange"] = _options.EventBus.ExchangeName,
                            ["x-dead-letter-routing-key"] = "OrderProcessed",
                        },
                        cancellationToken: stoppingToken);
                    await _channel.QueueBindAsync(
                        retryQueue, _options.EventBus.DeadLetterExchangeName, routingKey: retryQueue,
                        cancellationToken: stoppingToken);
                }

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderProcessedQueueName, durable: true, exclusive: false, autoDelete: false,
                    arguments: new Dictionary<string, object?>
                    {
                        ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
                    },
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessedQueueName, _options.EventBus.ExchangeName,
                    routingKey: "OrderProcessed", cancellationToken: stoppingToken);

                var consumer = new AsyncEventingBasicConsumer(_channel);
                consumer.ReceivedAsync += OnMessageReceivedAsync;

                await _channel.BasicConsumeAsync(
                    _options.EventBus.OrderProcessedQueueName, autoAck: false, consumerTag: string.Empty,
                    noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);

                // A second channel, used only to requeue an early completion,
                // with publisher confirms and confirmation tracking on -- the
                // same two flags Order Service's own outbox publisher uses, for
                // the same reason (RabbitMqOutboxPublisher's doc comment). They
                // are on a separate channel rather than on the consuming one
                // because turning confirms on changes how the consumer's own
                // ack/nack path is framed, and this channel exists to make one
                // thing true: an unroutable or nacked requeue publish throws
                // instead of returning quietly, so the original is never acked
                // for a retry that never actually reached a queue.
                _requeueChannel = await _connection.CreateChannelAsync(
                    new CreateChannelOptions(
                        publisherConfirmationsEnabled: true,
                        publisherConfirmationTrackingEnabled: true),
                    cancellationToken: stoppingToken);

                _logger.LogInformation(
                    "Consuming OrderProcessed from queue '{Queue}'", _options.EventBus.OrderProcessedQueueName);

                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OrderProcessed consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task OnMessageReceivedAsync(object sender, BasicDeliverEventArgs eventArgs)
    {
        try
        {
            var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());
            var orderProcessed = JsonSerializer.Deserialize<OrderProcessedEto>(body)
                ?? throw new InvalidOperationException("OrderProcessedEto deserialized to null.");

            using var correlationScope = LogContext.PushProperty("CorrelationId", orderProcessed.CorrelationId);

            _logger.LogInformation(
                "Received OrderProcessed {MessageId} for order {OrderId}",
                orderProcessed.MessageId, orderProcessed.OrderId);

            var outcome = await ProcessWithRetryAsync(orderProcessed);

            switch (outcome)
            {
                case ResultProcessingOutcome.Applied:
                    OrderMetrics.OrdersByOutcome.WithLabels(nameof(OrderState.Completed)).Inc();
                    _logger.LogInformation("Order {OrderId} -> Completed", orderProcessed.OrderId);
                    break;
                case ResultProcessingOutcome.NotYetApplicable:
                    // The completion is real but early: the order has not been
                    // Confirmed yet, because Inventory Service's StockReserved
                    // has not been applied here. Nothing was written for it --
                    // not even an Inbox row, so the copy that comes back is
                    // still processable. Requeue it with a delay and ack the
                    // original, which is the bounded-retry treatment
                    // docs/design-decisions.md section 2 defines for this case.
                    // If the ladder is already exhausted the message goes to
                    // the DLQ instead of waiting forever, exactly as a
                    // persistent processing failure would.
                    var attempt = RequeueAttempt(eventArgs);
                    if (attempt < RequeueDelays.Length)
                    {
                        var nextAttempt = attempt + 1;
                        _logger.LogInformation(
                            "OrderProcessed {MessageId} for order {OrderId} arrived before its StockReserved; requeuing attempt {Attempt}/{MaxAttempts} to '{Queue}'",
                            orderProcessed.MessageId, orderProcessed.OrderId, nextAttempt, RequeueDelays.Length,
                            RetryQueueName(nextAttempt - 1));
                        // RequeueForRetryAsync throws if the copy does not reach
                        // a queue (see its own doc comment), so this ack only
                        // runs once the retry is confirmed and the completion
                        // cannot be lost; a throw lands in the generic catch
                        // below and dead-letters the original loudly instead.
                        await RequeueForRetryAsync(eventArgs, orderProcessed, nextAttempt);
                        await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
                        return;
                    }

                    _logger.LogError(
                        "OrderProcessed {MessageId} for order {OrderId} is still early after {MaxAttempts} attempts; the order is still {State}; routing to DLQ",
                        orderProcessed.MessageId, orderProcessed.OrderId, RequeueDelays.Length, OrderState.PendingStock);
                    await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
                    return;
                case ResultProcessingOutcome.OrderNotFound:
                    _logger.LogWarning(
                        "Received a completion for unknown order {OrderId}; acking without action",
                        orderProcessed.OrderId);
                    break;
                case ResultProcessingOutcome.AlreadyProcessed:
                    // Expected whenever the Process Worker replays: it derives
                    // MessageId from OrderId, so a redelivered StockReserved
                    // produces the identical completion message and the Week 9
                    // Inbox recognises it here.
                    _logger.LogInformation(
                        "OrderProcessed {MessageId} for order {OrderId} already processed; acking as no-op",
                        orderProcessed.MessageId, orderProcessed.OrderId);
                    break;
            }

            // Week 9 crash test only (TP-M01): no-op unless configured.
            FaultInjection.CrashBeforeAckIfTargeted(_configuration, "OrderProcessed", orderProcessed.CorrelationId, _logger);
            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (InvalidOrderStateTransitionException ex)
        {
            // A completion for an order that is not Confirmed -- e.g. one that
            // was Rejected. Deterministic, so retrying cannot fix it; straight
            // to the DLQ, loudly, exactly as StockResultConsumer treats the
            // same class of conflict.
            _logger.LogError(ex, "Order state conflict processing a completion event; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process completion event after retries; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    private async Task<ResultProcessingOutcome> ProcessWithRetryAsync(OrderProcessedEto orderProcessed)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
                return await StockResultProcessor.ProcessAsync(
                    dbContext, orderProcessed.OrderId, orderProcessed.MessageId, "OrderProcessed", OrderState.Completed);
            }
            catch (InvalidOrderStateTransitionException)
            {
                throw;
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex,
                        "Failed to process OrderProcessed {MessageId} for order {OrderId} after {Attempts} attempts; routing to DLQ",
                        orderProcessed.MessageId, orderProcessed.OrderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to process OrderProcessed {MessageId} for order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    orderProcessed.MessageId, orderProcessed.OrderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay);
            }
        }

        throw new UnreachableException(); // the loop above always returns or rethrows
    }

    /// <summary>
    /// How many times this delivery has already been requeued for being early
    /// (0 on its first arrival). Carried in a header, so it survives the round
    /// trip through a retry queue and the broker's own dead-lettering.
    /// </summary>
    private static int RequeueAttempt(BasicDeliverEventArgs eventArgs)
    {
        if (eventArgs.BasicProperties?.Headers is null ||
            !eventArgs.BasicProperties.Headers.TryGetValue(RetryAttemptHeader, out var value))
        {
            return 0;
        }

        // RabbitMQ hands an AMQP field-table integer back as a byte (the type
        // the publisher chose), but a message crafted by hand or by a future
        // producer could use a wider type -- accept any of them rather than
        // failing the delivery over an encoding choice.
        return value switch
        {
            byte b => b,
            sbyte sb => sb,
            short s => s,
            int i => i,
            long l => (int)l,
            _ => 0,
        };
    }

    /// <summary>
    /// Publishes the next copy of an early completion onto the retry queue for
    /// the given attempt (see RetryQueueName): a fresh publish with the attempt
    /// header incremented. A new message rather than a nack-with-requeue
    /// because RabbitMQ has no per-message redelivery delay, and requeueing
    /// straight back onto the main queue would spin this message against a
    /// limited number of consumer threads for the whole ladder instead of
    /// letting it wait.
    ///
    /// Two things make this publish trustworthy, and both are load-bearing:
    /// the retry queues are bound to the dead-letter exchange (ExecuteAsync), so
    /// the message is routable; and the publish goes out on
    /// <see cref="_requeueChannel"/>, which has publisher confirms and
    /// confirmation tracking enabled, so <c>BasicPublishAsync</c> returns only
    /// once the broker has confirmed the message and *throws*
    /// (<c>PublishException</c>) if it was returned as unroutable or nacked.
    /// That is what lets the caller ack the original afterwards in good faith:
    /// with a plain channel and no binding this publish returned successfully
    /// while the message went nowhere, and the acked original was simply lost.
    ///
    /// Publishing before the caller acks is deliberate, and matches every other
    /// producer here: a crash in between leaves the original unacknowledged, so
    /// the broker redelivers it and the retry happens again -- at worst a
    /// duplicate copy, never a lost completion.
    /// </summary>
    private async Task RequeueForRetryAsync(
        BasicDeliverEventArgs eventArgs, OrderProcessedEto orderProcessed, int nextAttempt)
    {
        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = "OrderProcessed",
            CorrelationId = orderProcessed.CorrelationId,
            Headers = new Dictionary<string, object?> { [RetryAttemptHeader] = (byte)nextAttempt },
        };

        await _requeueChannel!.BasicPublishAsync(
            _options.EventBus.DeadLetterExchangeName,
            RetryQueueName(nextAttempt - 1),
            mandatory: true,
            basicProperties: properties,
            body: eventArgs.Body,
            cancellationToken: CancellationToken.None);
    }

    public override void Dispose()
    {
        _requeueChannel?.Dispose();
        _channel?.Dispose();
        _connection?.Dispose();
        base.Dispose();
    }
}
