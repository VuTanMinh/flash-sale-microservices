using System.Diagnostics;
using System.Text;
using System.Text.Json;
using FlashSale.EventContracts;
using Microsoft.Extensions.Options;
using Prometheus;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Serilog.Context;

namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// The Process Worker itself (Step 11.1): consumes StockReserved, waits a
/// deterministic delay, publishes OrderProcessed. That is the entire
/// service. Proposal §3 scopes it to simulating downstream processing with
/// a deterministic delay and a success result -- there is deliberately no
/// payment step, no failure injection and no compensation logic here, since
/// docs/00-scope-lock.md excludes all three and Step 11.1 warns specifically
/// against adding them "just in case".
///
/// Idempotency (Step 11.1's "uses order_id as its own idempotency key")
/// without any local store: the published OrderProcessed carries
/// MessageId = OrderId (see OrderProcessedEto). A redelivered StockReserved
/// therefore regenerates a byte-identical OrderProcessed, which Order
/// Service's Week 9 Inbox recognises and drops. Contrast Inventory Service
/// in Week 8, which DID need its own outbox table: its business fact landed
/// in Redis while the notification had to land in Postgres, so the two could
/// disagree. Nothing here writes anything locally, so there is nothing to
/// disagree with.
/// </summary>
public class StockReservedConsumer : BackgroundService
{
    // Same retry ladder as every other consumer in this system (Week 10).
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries

    private static readonly Counter ProcessedTotal = Metrics.CreateCounter(
        "flashsale_orders_processed_total",
        "Orders the Process Worker has completed and published OrderProcessed for.");

    private static readonly Counter DeadLetteredTotal = Metrics.CreateCounter(
        "flashsale_process_worker_dead_lettered_total",
        "StockReserved messages the Process Worker gave up on and routed to the DLQ.");

    private static readonly Histogram ProcessingDuration = Metrics.CreateHistogram(
        "flashsale_process_worker_duration_seconds",
        "Wall-clock time from receiving StockReserved to a confirmed OrderProcessed publish.");

    private readonly RabbitMqOptions _options;
    private readonly ProcessingOptions _processingOptions;
    private readonly OrderProcessedPublisher _publisher;
    private readonly ILogger<StockReservedConsumer> _logger;
    private IConnection? _connection;
    private IChannel? _channel;
    private CancellationToken _stoppingToken;

    public StockReservedConsumer(
        IOptions<RabbitMqOptions> options,
        IOptions<ProcessingOptions> processingOptions,
        OrderProcessedPublisher publisher,
        ILogger<StockReservedConsumer> logger)
    {
        _options = options.Value;
        _processingOptions = processingOptions.Value;
        _publisher = publisher;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _stoppingToken = stoppingToken;

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
                    _options.EventBus.StockReservedDeadLetterQueueName, durable: true, exclusive: false,
                    autoDelete: false, cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.StockReservedDeadLetterQueueName, _options.EventBus.DeadLetterExchangeName,
                    routingKey: _options.EventBus.DeadLetterRoutingKey, cancellationToken: stoppingToken);

                // x-dead-letter-routing-key rewrites the key on the way out so
                // this service's dead letters land only in ITS dlq, not also in
                // Order Service's (both share flashsale.dlx) -- see the option's
                // own doc comment.
                await _channel.QueueDeclareAsync(
                    _options.EventBus.StockReservedQueueName, durable: true, exclusive: false, autoDelete: false,
                    arguments: new Dictionary<string, object?>
                    {
                        ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
                        ["x-dead-letter-routing-key"] = _options.EventBus.DeadLetterRoutingKey,
                    },
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.StockReservedQueueName, _options.EventBus.ExchangeName,
                    routingKey: "StockReserved", cancellationToken: stoppingToken);

                var consumer = new AsyncEventingBasicConsumer(_channel);
                consumer.ReceivedAsync += OnMessageReceivedAsync;

                await _channel.BasicConsumeAsync(
                    _options.EventBus.StockReservedQueueName, autoAck: false, consumerTag: string.Empty,
                    noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);

                _logger.LogInformation(
                    "Consuming StockReserved from queue '{Queue}' with a {Delay}ms deterministic processing delay",
                    _options.EventBus.StockReservedQueueName, _processingOptions.DelayMilliseconds);

                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Process Worker consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task OnMessageReceivedAsync(object sender, BasicDeliverEventArgs eventArgs)
    {
        var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());

        try
        {
            var stockReserved = JsonSerializer.Deserialize<StockReservedEto>(body)
                ?? throw new InvalidOperationException("StockReservedEto deserialized to null.");

            // Every log line below carries the correlation id this order
            // started with (Step 11.2) -- including the publisher's, since
            // LogContext flows through the awaits.
            using var correlationScope = LogContext.PushProperty("CorrelationId", stockReserved.CorrelationId);

            _logger.LogInformation(
                "Received StockReserved for order {OrderId}; starting downstream processing",
                stockReserved.OrderId);

            await ProcessWithRetryAsync(stockReserved);

            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (Exception ex)
        {
            // Either the payload never deserialized (retrying identical bytes
            // cannot help) or ProcessWithRetryAsync exhausted its attempts.
            DeadLetteredTotal.Inc();
            _logger.LogError(ex, "Failed to process StockReserved message; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    private async Task ProcessWithRetryAsync(StockReservedEto stockReserved)
    {
        var stopwatch = Stopwatch.StartNew();

        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                // The simulated downstream work. Deterministic by design
                // (ProcessingOptions explains why), and deliberately INSIDE
                // the retry loop: a retry re-does the work rather than
                // publishing a completion for processing that never actually
                // ran to completion the first time.
                await Task.Delay(_processingOptions.DelayMilliseconds, _stoppingToken);

                await _publisher.PublishAsync(
                    new OrderProcessedEto
                    {
                        OrderId = stockReserved.OrderId,
                        // Not a fresh Guid: see OrderProcessedEto.MessageId.
                        MessageId = stockReserved.OrderId,
                        CorrelationId = stockReserved.CorrelationId,
                    },
                    _stoppingToken);

                stopwatch.Stop();
                ProcessedTotal.Inc();
                ProcessingDuration.Observe(stopwatch.Elapsed.TotalSeconds);

                _logger.LogInformation(
                    "Order {OrderId} processed in {ElapsedMs}ms; published OrderProcessed",
                    stockReserved.OrderId, stopwatch.ElapsedMilliseconds);
                return;
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex, "Failed to process order {OrderId} after {Attempts} attempts; routing to DLQ",
                        stockReserved.OrderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex, "Failed to process order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    stockReserved.OrderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay, _stoppingToken);
            }
        }

        throw new UnreachableException(); // the loop above always returns or rethrows
    }

    public override void Dispose()
    {
        _channel?.Dispose();
        _connection?.Dispose();
        base.Dispose();
    }
}
