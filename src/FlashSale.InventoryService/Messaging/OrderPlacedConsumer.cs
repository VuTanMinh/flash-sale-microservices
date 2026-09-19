using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.InventoryService.Data;
using FlashSale.InventoryService.Inventory;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using Serilog.Context;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Consumes OrderPlacedEto from RabbitMQ, calls the Redis Lua reservation
/// script, and (Week 8) ensures a StockReserved/StockRejected outbox row
/// exists for the order, published by this service's own
/// OutboxPublisherWorker.
///
/// Consumes via raw RabbitMQ.Client, not Volo.Abp.EventBus.RabbitMQ's
/// IDistributedEventHandler, for the same reason Order Service's
/// OutboxPublisherWorker publishes via the raw client (see that class's own
/// doc comment): messages here are published as plain JSON with a routing
/// key, not through ABP's own event-bus envelope, so an ABP-level consumer
/// would not be looking at the same message shape a hand-rolled publisher
/// produces. Keeping publish and consume on the same raw primitives end to
/// end avoids that mismatch entirely.
///
/// The actual idempotency logic (Inbox check by MessageId, Lua reservation,
/// ensure-outbox-row, Inbox insert) lives in
/// <see cref="OrderPlacedProcessor"/> (Week 9) -- this class is only broker
/// plumbing around it. Acked only after that processing completes, so a
/// crash mid-processing (Step 9.3) results in RabbitMQ redelivering the
/// message rather than losing it, and reprocessing it is safe by
/// construction (Inbox check, Redis's own DUPLICATE handling, and the
/// outbox's unique-OrderId index all cover different parts of the same
/// guarantee).
/// </summary>
public class OrderPlacedConsumer : BackgroundService
{
    // Same schedule as OutboxPublisherWorker's own retry-with-backoff (Week
    // 6) -- consumer-side processing failures (Step 10.1, e.g. a transient
    // Redis or Postgres hiccup) get bounded retries before this message is
    // given up on, distinct from the connection-level 5s reconnect loop in
    // ExecuteAsync below, which handles broker outages, not handler errors.
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<OrderPlacedConsumer> _logger;
    private IConnection? _connection;
    private IChannel? _channel;

    public OrderPlacedConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<OrderPlacedConsumer> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
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

        // Reconnect-with-backoff loop: a transient broker outage at startup
        // (e.g. RabbitMQ still starting in Docker Compose) should not crash
        // this service, matching the same "don't let broker hiccups take the
        // whole worker down" reasoning as Order Service's OutboxPublisherWorker.
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                _connection = await factory.CreateConnectionAsync(stoppingToken);
                _channel = await _connection.CreateChannelAsync(cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.ExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                // Dead-letter exchange + queue (Step 10.2): a separate direct
                // exchange from the main one above, so a message that exhausts
                // OnMessageReceivedAsync's retries and gets nacked without
                // requeue lands somewhere an operator has to look, rather than
                // being silently dropped or looping the main queue forever.
                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.DeadLetterExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderPlacedDeadLetterQueueName, durable: true, exclusive: false, autoDelete: false,
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderPlacedDeadLetterQueueName, _options.EventBus.DeadLetterExchangeName,
                    routingKey: "OrderPlaced", cancellationToken: stoppingToken);

                // x-dead-letter-exchange on the MAIN queue's own arguments is
                // what actually routes a requeue:false'd message to the DLX
                // above -- RabbitMQ re-publishes it there with its original
                // routing key preserved, which is why the DLQ binding above
                // uses the same "OrderPlaced" routing key rather than a
                // wildcard.
                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderPlacedQueueName, durable: true, exclusive: false, autoDelete: false,
                    arguments: new Dictionary<string, object?>
                    {
                        ["x-dead-letter-exchange"] = _options.EventBus.DeadLetterExchangeName,
                    },
                    cancellationToken: stoppingToken);

                await _channel.QueueBindAsync(
                    _options.EventBus.OrderPlacedQueueName, _options.EventBus.ExchangeName, routingKey: "OrderPlaced",
                    cancellationToken: stoppingToken);

                var consumer = new AsyncEventingBasicConsumer(_channel);
                consumer.ReceivedAsync += OnMessageReceivedAsync;

                // Manual ack (autoAck: false) -- see this class's own doc
                // comment on why acknowledgement is still simple this week.
                await _channel.BasicConsumeAsync(
                    _options.EventBus.OrderPlacedQueueName, autoAck: false, consumerTag: string.Empty,
                    noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);

                _logger.LogInformation(
                    "Consuming OrderPlaced from queue '{Queue}'", _options.EventBus.OrderPlacedQueueName);

                // Idle until cancellation or the connection drops; RabbitMQ.Client
                // delivers messages on its own background threads via the
                // consumer's ReceivedAsync event, not by this method looping.
                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OrderPlaced consumer connection failed; retrying in 5s");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    private async Task OnMessageReceivedAsync(object sender, BasicDeliverEventArgs eventArgs)
    {
        var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());

        try
        {
            var orderPlaced = JsonSerializer.Deserialize<OrderPlacedEto>(body)
                ?? throw new InvalidOperationException("OrderPlacedEto deserialized to null.");

            // Week 11, Step 11.2: tags every log line produced while handling
            // this message -- including OrderPlacedProcessor's and the Lua
            // wrapper's, since LogContext flows across the awaits below -- with
            // the correlation id the order started with in Order Service.
            using var correlationScope = LogContext.PushProperty("CorrelationId", orderPlaced.CorrelationId);

            _logger.LogInformation(
                "Received OrderPlaced {MessageId} for order {OrderId}", orderPlaced.MessageId, orderPlaced.OrderId);

            var outcome = await ProcessWithRetryAsync(orderPlaced);

            if (outcome == OrderPlacedProcessingOutcome.AlreadyProcessed)
            {
                _logger.LogInformation(
                    "OrderPlaced {MessageId} for order {OrderId} already processed; acking as no-op",
                    orderPlaced.MessageId, orderPlaced.OrderId);
            }

            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (Exception ex)
        {
            // Either the message never deserialized (retrying wouldn't help --
            // the bytes don't change) or ProcessWithRetryAsync below already
            // exhausted MaxAttempts and logged it. Either way, nack without
            // requeue routes it to the DLQ (via the main queue's
            // x-dead-letter-exchange argument, Step 10.2) instead of looping
            // it back onto this same queue forever.
            _logger.LogError(ex, "Failed to process OrderPlaced message; routing to DLQ");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
    }

    /// <summary>
    /// Step 10.1: bounded retry with exponential backoff for consumer-side
    /// processing failures (a transient Redis/Postgres error inside
    /// OrderPlacedProcessor), as distinct from delivery failures (handled by
    /// RabbitMQ itself) or broker connection failures (ExecuteAsync's own 5s
    /// reconnect loop above). Volo.Abp.EventBus.RabbitMQ was checked and does
    /// not apply here at all -- this project doesn't use it (see this class's
    /// own doc comment) -- so this is implemented directly, matching
    /// OutboxPublisherWorker's already-established retry shape.
    ///
    /// Retrying the whole call (not just the Lua reservation) is safe because
    /// OrderPlacedProcessor is itself idempotent: a retry that lands after a
    /// prior attempt actually succeeded just sees AlreadyProcessed via the
    /// Inbox check and returns cleanly, rather than double-processing.
    /// </summary>
    private async Task<OrderPlacedProcessingOutcome> ProcessWithRetryAsync(OrderPlacedEto orderPlaced)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var reservationService = scope.ServiceProvider.GetRequiredService<InventoryReservationService>();
                var dbContext = scope.ServiceProvider.GetRequiredService<InventoryServiceDbContext>();
                return await OrderPlacedProcessor.ProcessAsync(dbContext, reservationService, orderPlaced, _logger);
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex,
                        "Failed to process OrderPlaced {MessageId} for order {OrderId} after {Attempts} attempts; routing to DLQ",
                        orderPlaced.MessageId, orderPlaced.OrderId, attempt);
                    throw;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to process OrderPlaced {MessageId} for order {OrderId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    orderPlaced.MessageId, orderPlaced.OrderId, attempt, MaxAttempts, delay);
                await Task.Delay(delay);
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
