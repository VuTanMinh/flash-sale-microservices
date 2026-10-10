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
/// Consumes StockReserved/StockRejected from Inventory Service and
/// transitions the matching order (checklist Step 8.2): PendingStock ->
/// Confirmed or PendingStock -> Rejected, per docs/order-state-machine.md.
///
/// Two separate queues, one per event type, each bound to
/// flashsale.order.exchange with that type name as the routing key --
/// mirrors how Inventory Service's OutboxPublisherWorker publishes (routing
/// key = event type) and how Order Service's own OutboxPublisherWorker
/// already does the same thing for OrderPlaced. Raw RabbitMQ.Client for the
/// same reason as every other consumer/publisher pair in this project: the
/// messages aren't in ABP's own event-bus envelope.
///
/// The actual idempotency logic (Inbox check, transition, Inbox insert, all
/// in one transaction) lives in <see cref="StockResultProcessor"/> -- this
/// class is only broker plumbing (ack/nack, deserialization) around it.
/// Acked only after that transaction commits, so a crash between "processed"
/// and "acked" (Step 9.3) results in RabbitMQ redelivering the message, not
/// silently losing it -- and the redelivery is safe precisely because the
/// Inbox check makes reprocessing it a no-op.
/// </summary>
public class StockResultConsumer : BackgroundService
{
    // Same retry-with-backoff shape as OutboxPublisherWorker (Week 6) and
    // Inventory Service's OrderPlacedConsumer (Week 10) -- see either for the
    // fuller reasoning. Bounds consumer-side processing failures, distinct
    // from the connection-level 5s reconnect loop in ExecuteAsync below.
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<StockResultConsumer> _logger;
    private readonly IConfiguration _configuration;
    private IConnection? _connection;
    private IChannel? _channel;

    public StockResultConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<StockResultConsumer> logger,
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

                // Dead-letter exchange (Step 10.2) -- see Inventory Service's
                // OrderPlacedConsumer for the fuller reasoning; same idea here,
                // one DLQ per main queue since StockReserved and StockRejected
                // are independent queues with independent failure histories.
                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.DeadLetterExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await BindAndConsumeAsync(
                    _options.EventBus.StockReservedQueueName, "StockReserved",
                    _options.EventBus.StockReservedDeadLetterQueueName, OnStockReservedAsync, stoppingToken);
                await BindAndConsumeAsync(
                    _options.EventBus.StockRejectedQueueName, "StockRejected",
                    _options.EventBus.StockRejectedDeadLetterQueueName, OnStockRejectedAsync, stoppingToken);

                _logger.LogInformation(
                    "Consuming StockReserved from '{ReservedQueue}' and StockRejected from '{RejectedQueue}'",
                    _options.EventBus.StockReservedQueueName, _options.EventBus.StockRejectedQueueName);

                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "StockResult consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task BindAndConsumeAsync(
        string queueName, string routingKey, string deadLetterQueueName,
        AsyncEventHandler<BasicDeliverEventArgs> handler, CancellationToken stoppingToken)
    {
        await _channel!.QueueDeclareAsync(
            deadLetterQueueName, durable: true, exclusive: false, autoDelete: false, cancellationToken: stoppingToken);
        await _channel.QueueBindAsync(
            deadLetterQueueName, _options.EventBus.DeadLetterExchangeName, routingKey, cancellationToken: stoppingToken);

        // x-dead-letter-exchange here is what routes a requeue:false'd message
        // to the DLX (and from there, via the matching routing key, to the
        // DLQ bound above) instead of it vanishing when nacked.
        await _channel.QueueDeclareAsync(
            queueName, durable: true, exclusive: false, autoDelete: false,
            arguments: new Dictionary<string, object?>
            {
                ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
            },
            cancellationToken: stoppingToken);
        await _channel.QueueBindAsync(
            queueName, _options.EventBus.ExchangeName, routingKey, cancellationToken: stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(_channel);
        consumer.ReceivedAsync += handler;

        await _channel.BasicConsumeAsync(
            queueName, autoAck: false, consumerTag: string.Empty,
            noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);
    }

    private Task OnStockReservedAsync(object sender, BasicDeliverEventArgs eventArgs) =>
        HandleResultAsync(eventArgs, OrderState.Confirmed, "StockReserved", body =>
        {
            var eto = JsonSerializer.Deserialize<StockReservedEto>(body);
            return eto is null ? null : (eto.OrderId, eto.MessageId, eto.CorrelationId, eto.ProductId);
        });

    private Task OnStockRejectedAsync(object sender, BasicDeliverEventArgs eventArgs) =>
        HandleResultAsync(eventArgs, OrderState.Rejected, "StockRejected", body =>
        {
            var eto = JsonSerializer.Deserialize<StockRejectedEto>(body);
            return eto is null ? null : (eto.OrderId, eto.MessageId, eto.CorrelationId, eto.ProductId);
        });

    private async Task HandleResultAsync(
        BasicDeliverEventArgs eventArgs, OrderState targetState, string eventType,
        Func<string, (Guid OrderId, Guid MessageId, string CorrelationId, string ProductId)?> extract)
    {
        try
        {
            var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());
            var (orderId, messageId, correlationId, productId) = extract(body)
                ?? throw new InvalidOperationException("Result event deserialized with no OrderId/MessageId.");

            // Week 10 (Step 10.2): see OrderPlacedConsumer for the fuller
            // reasoning -- an empty identity field is permanent and is nacked
            // straight to this service's DLQ, with no retries and no Inbox or
            // state change (docs/failure-handling.md).
            var invalidField = InvalidField(orderId, messageId, productId);
            if (invalidField is not null)
            {
                _logger.LogError("Invalid {EventType} message: {Field} is empty; routing to DLQ", eventType, invalidField);
                await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
                return;
            }

            // Week 11, Step 11.2 -- see OrderPlacedConsumer for the fuller note.
            using var correlationScope = LogContext.PushProperty("CorrelationId", correlationId);

            _logger.LogInformation(
                "Received {EventType} {MessageId} for order {OrderId}", eventType, messageId, orderId);

            var outcome = await ProcessWithRetryAsync(orderId, messageId, eventType, targetState);

            switch (outcome)
            {
                case ResultProcessingOutcome.Applied:
                    // Only Applied increments: AlreadyProcessed means some
                    // earlier delivery already counted this order, and counting
                    // it twice would make the metric disagree with the database
                    // precisely under the redelivery conditions Week 13/14 is
                    // trying to measure.
                    OrderMetrics.OrdersByOutcome.WithLabels(targetState.ToString()).Inc();
                    _logger.LogInformation("Order {OrderId} -> {State}", orderId, targetState);
                    break;
                case ResultProcessingOutcome.OrderNotFound:
                    // The order genuinely doesn't exist -- redelivery after Week
                    // 13/14 test data was reset, most likely. Nothing to transition.
                    _logger.LogWarning("Received a result for unknown order {OrderId}; acking without action", orderId);
                    break;
                case ResultProcessingOutcome.AlreadyProcessed:
                    _logger.LogInformation(
                        "{EventType} {MessageId} for order {OrderId} already processed; acking as no-op",
                        eventType, messageId, orderId);
                    break;
                case ResultProcessingOutcome.NotYetApplicable:
                    // Unreachable for a stock result: "the prerequisite has not
                    // been applied yet" only describes OrderProcessed arriving
                    // before StockReserved, and StockReserved is that
                    // prerequisite (StockResultProcessor.IsAwaitingPrerequisite).
                    // Handled explicitly rather than left out so that if a stock
                    // result ever gets here, the switch says so instead of
                    // quietly acking a result the order never received.
                    _logger.LogError(
                        "{EventType} {MessageId} for order {OrderId} reported as waiting for a prerequisite; a stock result has none",
                        eventType, messageId, orderId);
                    OrderMetrics.OrdersByOutcome.WithLabels("NotYetApplicable").Inc();
                    break;
            }

            // Week 9 crash test only (TP-M01): no-op unless configured.
            FaultInjection.CrashBeforeAckIfTargeted(_configuration, "StockResult", correlationId, _logger);
            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (InvalidOrderStateTransitionException ex)
        {
            // A genuine conflict (e.g. already Rejected, now told Reserved) --
            // not something a retry will resolve, since the order's state
            // doesn't change between attempts on its own; ProcessWithRetryAsync
            // deliberately skips its retry loop for this exact exception and
            // rethrows immediately, so this is reached on the very first
            // attempt, not after wasting 1s+2s+4s retrying something retrying
            // can't fix. Logged loudly and routed to the DLQ (Step 10.2) for
            // manual inspection rather than silently dropped or retried forever.
            _logger.LogError(ex, "Order state conflict processing a result event; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
        catch (Exception ex)
        {
            // ProcessWithRetryAsync exhausted all MaxAttempts retries above
            // (or deserialization itself failed, which isn't retryable
            // either). Nack without requeue routes it to the DLQ instead of
            // looping it back onto this same queue forever.
            _logger.LogError(ex, "Failed to process result event after retries; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    /// <summary>
    /// Step 10.1: bounded retry with exponential backoff for consumer-side
    /// processing failures, mirroring Inventory Service's OrderPlacedConsumer
    /// (see its own doc comment for the fuller reasoning on why this is
    /// implemented directly rather than via Volo.Abp.EventBus.RabbitMQ).
    /// <see cref="InvalidOrderStateTransitionException"/> is deliberately
    /// exempted from the retry loop -- it is a genuine, deterministic
    /// conflict (the order's actual state disagrees with what this message
    /// claims), not a transient failure, so retrying it three times with
    /// backoff would just reproduce the identical exception three times for
    /// no benefit. Every other exception gets the full retry treatment before
    /// giving up.
    /// </summary>
    private async Task<ResultProcessingOutcome> ProcessWithRetryAsync(
        Guid orderId, Guid messageId, string eventType, OrderState targetState)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
                return await StockResultProcessor.ProcessAsync(dbContext, orderId, messageId, eventType, targetState);
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
                        "Failed to process {EventType} {MessageId} for order {OrderId} after {Attempts} attempts; routing to DLQ",
                        eventType, messageId, orderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to process {EventType} {MessageId} for order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    eventType, messageId, orderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay);
            }
        }

        throw new UnreachableException(); // the loop above always returns or rethrows
    }

    /// <summary>
    /// Week 10 (Step 10.2): the name of the first empty identity field, or null
    /// when the message is well-formed. An empty MessageId/OrderId/ProductId is
    /// permanent, so the caller nacks it straight to the DLQ rather than
    /// running the retry ladder (docs/failure-handling.md).
    /// </summary>
    private static string? InvalidField(Guid orderId, Guid messageId, string productId)
    {
        if (messageId == Guid.Empty) return "MessageId";
        if (orderId == Guid.Empty) return "OrderId";
        if (string.IsNullOrWhiteSpace(productId)) return "ProductId";
        return null;
    }

    public override void Dispose()
    {
        _channel?.Dispose();
        _connection?.Dispose();
        base.Dispose();
    }
}
