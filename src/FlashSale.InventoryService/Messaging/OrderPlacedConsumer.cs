using System;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.InventoryService.Inventory;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Consumes OrderPlacedEto from RabbitMQ and calls the Redis Lua reservation
/// script, branching on the three possible results (checklist Step 7.4).
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
/// Does not yet publish StockReserved/StockRejected back -- that is Week 8's
/// job (Step 8.1). This week's outcome is only logged, which is enough to
/// verify the reservation logic itself is being exercised correctly.
/// Acknowledgement here is a simple ack-after-success /
/// nack-and-requeue-on-failure; Week 9 replaces this with the full
/// Inbox-pattern-based idempotent acknowledgement strategy.
/// </summary>
public class OrderPlacedConsumer : BackgroundService
{
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

                await _channel.QueueDeclareAsync(
                    _options.EventBus.OrderPlacedQueueName, durable: true, exclusive: false, autoDelete: false,
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

            using var scope = _scopeFactory.CreateScope();
            var reservationService = scope.ServiceProvider.GetRequiredService<InventoryReservationService>();

            var result = await reservationService.ReserveAsync(
                orderPlaced.ProductId, orderPlaced.OrderId.ToString());

            _logger.LogInformation(
                "OrderPlaced {OrderId} for product {ProductId} -> {Result}",
                orderPlaced.OrderId, orderPlaced.ProductId, result);

            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process OrderPlaced message; requeueing");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: true);
        }
    }

    public override void Dispose()
    {
        _channel?.Dispose();
        _connection?.Dispose();
        base.Dispose();
    }
}
