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
/// Consumes OrderProcessingStarted from the Process Worker (Week 11 box 2) and
/// moves the order into Processing: Confirmed -> Processing, the transition that
/// closes the "the Worker has begun downstream work" gap in
/// docs/order-state-machine.md.
///
/// This class mirrors OrderProcessedConsumer deliberately rather than sharing a
/// base class: each Worker event gets its own queue, its own retry ladder and
/// its own delayed-requeue queues (see that consumer's doc comment for why the
/// two ladders are separate), and duplicating the ~250 lines of broker plumbing
/// is cheaper than a shared abstraction whose two users already diverge on every
/// string constant. The idempotent transition itself is NOT duplicated -- it
/// reuses StockResultProcessor.ProcessAsync with target Processing.
/// </summary>
public class OrderProcessingStartedConsumer : BackgroundService
{
    // Same two-ladder shape as OrderProcessedConsumer: RetryDelays bounds
    // in-process retries of a failing handler (1/2/4 s, then DLQ), while
    // RequeueDelays bounds how long a start event that arrived before its
    // StockReserved waits on a broker queue before it is tried again.
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    private static readonly TimeSpan[] RequeueDelays =
    [
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
    ];

    private const string RetryAttemptHeader = "x-order-processing-started-attempts";

    private static string RetryQueueName(int retryIndex) => $"OrderProcessingStarted.retry.{retryIndex + 1}";

    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<OrderProcessingStartedConsumer> _logger;
    private readonly IConfiguration _configuration;
    private IConnection? _connection;
    private IChannel? _channel;

    /// <summary>Publisher-confirming channel, used only by <see cref="RequeueForRetryAsync"/>.</summary>
    private IChannel? _requeueChannel;

    public OrderProcessingStartedConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<OrderProcessingStartedConsumer> logger,
        IConfiguration configuration)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
        _configuration = configuration;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Week 11 (TP-P04): export this consumer's metric series at 0 from start-up.
        ConsumerMetrics.Initialize("OrderProcessingStarted", requeuesEarly: true);
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
                    _options.EventBus.OrderProcessingStartedDeadLetterQueueName, durable: true, exclusive: false,
                    autoDelete: false, cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessingStartedDeadLetterQueueName, _options.EventBus.DeadLetterExchangeName,
                    routingKey: "OrderProcessingStarted", cancellationToken: stoppingToken);

                // Delayed retry queues, mirroring OrderProcessedConsumer's: a
                // start event that arrives before the order's StockReserved is
                // retried on these TTL queues (dead-lettered back to the main
                // queue), then the DLQ after three requeues.
                for (var attempt = 1; attempt <= RequeueDelays.Length; attempt++)
                {
                    var retryQueue = RetryQueueName(attempt - 1);
                    await _channel.QueueDeclareAsync(
                        retryQueue, durable: true, exclusive: false, autoDelete: false,
                        arguments: new Dictionary<string, object?>
                        {
                            ["x-message-ttl"] = (int)RequeueDelays[attempt - 1].TotalMilliseconds,
                            ["x-dead-letter-exchange"] = _options.EventBus.ExchangeName,
                            ["x-dead-letter-routing-key"] = "OrderProcessingStarted",
                        },
                        cancellationToken: stoppingToken);
                    await _channel.QueueBindAsync(
                        retryQueue, _options.EventBus.DeadLetterExchangeName, routingKey: retryQueue,
                        cancellationToken: stoppingToken);
                }

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderProcessingStartedQueueName, durable: true, exclusive: false, autoDelete: false,
                    arguments: new Dictionary<string, object?>
                    {
                        ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
                    },
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderProcessingStartedQueueName, _options.EventBus.ExchangeName,
                    routingKey: "OrderProcessingStarted", cancellationToken: stoppingToken);

                var consumer = new AsyncEventingBasicConsumer(_channel);
                consumer.ReceivedAsync += OnMessageReceivedAsync;

                await _channel.BasicConsumeAsync(
                    _options.EventBus.OrderProcessingStartedQueueName, autoAck: false, consumerTag: string.Empty,
                    noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);

                _requeueChannel = await _connection.CreateChannelAsync(
                    new CreateChannelOptions(
                        publisherConfirmationsEnabled: true,
                        publisherConfirmationTrackingEnabled: true),
                    cancellationToken: stoppingToken);

                _logger.LogInformation(
                    "Consuming OrderProcessingStarted from queue '{Queue}'", _options.EventBus.OrderProcessingStartedQueueName);

                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OrderProcessingStarted consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task OnMessageReceivedAsync(object sender, BasicDeliverEventArgs eventArgs)
    {
        try
        {
            var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());
            var orderProcessingStarted = JsonSerializer.Deserialize<OrderProcessingStartedEto>(body)
                ?? throw new InvalidOperationException("OrderProcessingStartedEto deserialized to null.");

            // Week 10 (Step 10.2): an empty MessageId/OrderId is permanent, so it
            // is nacked straight to this service's DLQ with no retries and no
            // Inbox or state change.
            var invalidField = InvalidField(orderProcessingStarted.OrderId, orderProcessingStarted.MessageId);
            if (invalidField is not null)
            {
                _logger.LogError("Invalid OrderProcessingStarted message: {Field} is empty; routing to DLQ", invalidField);
                ConsumerMetrics.DeadLettered.WithLabels("OrderProcessingStarted", "invalid").Inc();
                await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
                return;
            }

            using var correlationScope = LogContext.PushProperty("CorrelationId", orderProcessingStarted.CorrelationId);

            _logger.LogInformation(
                "Received OrderProcessingStarted {MessageId} for order {OrderId}",
                orderProcessingStarted.MessageId, orderProcessingStarted.OrderId);

            var outcome = await ProcessWithRetryAsync(orderProcessingStarted);

            switch (outcome)
            {
                case ResultProcessingOutcome.Applied:
                    OrderMetrics.OrdersByOutcome.WithLabels(nameof(OrderState.Processing)).Inc();
                    _logger.LogInformation("Order {OrderId} -> Processing", orderProcessingStarted.OrderId);
                    break;
                case ResultProcessingOutcome.NotYetApplicable:
                    var attempt = RequeueAttempt(eventArgs);
                    if (attempt < RequeueDelays.Length)
                    {
                        var nextAttempt = attempt + 1;
                        _logger.LogInformation(
                            "OrderProcessingStarted {MessageId} for order {OrderId} arrived before its StockReserved; requeuing attempt {Attempt}/{MaxAttempts} to '{Queue}'",
                            orderProcessingStarted.MessageId, orderProcessingStarted.OrderId, nextAttempt, RequeueDelays.Length,
                            RetryQueueName(nextAttempt - 1));
                        ConsumerMetrics.RequeuedEarly.WithLabels("OrderProcessingStarted").Inc();
                        await RequeueForRetryAsync(eventArgs, orderProcessingStarted, nextAttempt);
                        await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
                        return;
                    }

                    _logger.LogError(
                        "OrderProcessingStarted {MessageId} for order {OrderId} is still early after {MaxAttempts} attempts; the order is still {State}; routing to DLQ",
                        orderProcessingStarted.MessageId, orderProcessingStarted.OrderId, RequeueDelays.Length, OrderState.PendingStock);
                    ConsumerMetrics.DeadLettered.WithLabels("OrderProcessingStarted", "exhausted").Inc();
                    await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
                    return;
                case ResultProcessingOutcome.OrderNotFound:
                    _logger.LogWarning(
                        "Received a start event for unknown order {OrderId}; acking without action",
                        orderProcessingStarted.OrderId);
                    break;
                case ResultProcessingOutcome.AlreadyProcessed:
                    // Expected whenever the Process Worker replays: the derived
                    // MessageId is regenerated, so a redelivered StockReserved
                    // produces the identical start message and the Inbox
                    // recognises it. Also the "same or earlier state" no-op for a
                    // start event that arrives after the order is already
                    // Processing or Completed.
                    ConsumerMetrics.Duplicates.WithLabels("OrderProcessingStarted").Inc();
                    _logger.LogInformation(
                        "OrderProcessingStarted {MessageId} for order {OrderId} already processed; acking as no-op",
                        orderProcessingStarted.MessageId, orderProcessingStarted.OrderId);
                    break;
            }

            // Week 9 crash test only (TP-M01): no-op unless configured.
            FaultInjection.CrashBeforeAckIfTargeted(_configuration, "OrderProcessingStarted", orderProcessingStarted.CorrelationId, _logger);
            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (InvalidOrderStateTransitionException ex)
        {
            _logger.LogError(ex, "Order state conflict processing a start event; routing to DLQ");
            ConsumerMetrics.DeadLettered.WithLabels("OrderProcessingStarted", "conflict").Inc();
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process start event after retries; routing to DLQ");
            ConsumerMetrics.DeadLettered.WithLabels("OrderProcessingStarted", ex is System.Text.Json.JsonException ? "invalid" : "exhausted").Inc();
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    private async Task<ResultProcessingOutcome> ProcessWithRetryAsync(OrderProcessingStartedEto orderProcessingStarted)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
                return await StockResultProcessor.ProcessAsync(
                    dbContext, orderProcessingStarted.OrderId, orderProcessingStarted.MessageId,
                    "OrderProcessingStarted", OrderState.Processing);
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
                        "Failed to process OrderProcessingStarted {MessageId} for order {OrderId} after {Attempts} attempts; routing to DLQ",
                        orderProcessingStarted.MessageId, orderProcessingStarted.OrderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                ConsumerMetrics.Retries.WithLabels("OrderProcessingStarted").Inc();
                _logger.LogWarning(
                    ex,
                    "Failed to process OrderProcessingStarted {MessageId} for order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    orderProcessingStarted.MessageId, orderProcessingStarted.OrderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay);
            }
        }

        throw new UnreachableException(); // the loop above always returns or rethrows
    }

    private static string? InvalidField(Guid orderId, Guid messageId)
    {
        if (messageId == Guid.Empty) return "MessageId";
        if (orderId == Guid.Empty) return "OrderId";
        return null;
    }

    private static int RequeueAttempt(BasicDeliverEventArgs eventArgs)
    {
        if (eventArgs.BasicProperties?.Headers is null ||
            !eventArgs.BasicProperties.Headers.TryGetValue(RetryAttemptHeader, out var value))
        {
            return 0;
        }

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
    /// Publishes the next copy of an early start event onto the retry queue for
    /// the given attempt, with publisher confirms on <see cref="_requeueChannel"/>,
    /// so the caller only acks the original once the retry copy is confirmed.
    /// See OrderProcessedConsumer.RequeueForRetryAsync for the fuller reasoning.
    /// </summary>
    private async Task RequeueForRetryAsync(
        BasicDeliverEventArgs eventArgs, OrderProcessingStartedEto orderProcessingStarted, int nextAttempt)
    {
        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = "OrderProcessingStarted",
            CorrelationId = orderProcessingStarted.CorrelationId,
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
