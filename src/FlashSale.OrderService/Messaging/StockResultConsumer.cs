using System;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

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
/// </summary>
public class StockResultConsumer : BackgroundService
{
    private readonly RabbitMqOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<StockResultConsumer> _logger;
    private IConnection? _connection;
    private IChannel? _channel;

    public StockResultConsumer(
        IOptions<RabbitMqOptions> options, IServiceScopeFactory scopeFactory, ILogger<StockResultConsumer> logger)
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

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                _connection = await factory.CreateConnectionAsync(stoppingToken);
                _channel = await _connection.CreateChannelAsync(cancellationToken: stoppingToken);

                await _channel.ExchangeDeclareAsync(
                    _options.EventBus.ExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                    cancellationToken: stoppingToken);

                await BindAndConsumeAsync(
                    _options.EventBus.StockReservedQueueName, "StockReserved", OnStockReservedAsync, stoppingToken);
                await BindAndConsumeAsync(
                    _options.EventBus.StockRejectedQueueName, "StockRejected", OnStockRejectedAsync, stoppingToken);

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
        string queueName, string routingKey, AsyncEventHandler<BasicDeliverEventArgs> handler, CancellationToken stoppingToken)
    {
        await _channel!.QueueDeclareAsync(
            queueName, durable: true, exclusive: false, autoDelete: false, cancellationToken: stoppingToken);
        await _channel.QueueBindAsync(
            queueName, _options.EventBus.ExchangeName, routingKey, cancellationToken: stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(_channel);
        consumer.ReceivedAsync += handler;

        await _channel.BasicConsumeAsync(
            queueName, autoAck: false, consumerTag: string.Empty,
            noLocal: false, exclusive: false, arguments: null, consumer, stoppingToken);
    }

    private Task OnStockReservedAsync(object sender, BasicDeliverEventArgs eventArgs) =>
        HandleResultAsync(eventArgs, OrderState.Confirmed, body => JsonSerializer.Deserialize<StockReservedEto>(body)?.OrderId);

    private Task OnStockRejectedAsync(object sender, BasicDeliverEventArgs eventArgs) =>
        HandleResultAsync(eventArgs, OrderState.Rejected, body => JsonSerializer.Deserialize<StockRejectedEto>(body)?.OrderId);

    private async Task HandleResultAsync(
        BasicDeliverEventArgs eventArgs, OrderState targetState, Func<string, Guid?> extractOrderId)
    {
        try
        {
            var body = Encoding.UTF8.GetString(eventArgs.Body.ToArray());
            var orderId = extractOrderId(body)
                ?? throw new InvalidOperationException("Result event deserialized with no OrderId.");

            using var scope = _scopeFactory.CreateScope();
            var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();

            var order = await dbContext.Orders.FirstOrDefaultAsync(o => o.Id == orderId);
            if (order is null)
            {
                // The order genuinely doesn't exist -- redelivery after Week
                // 13/14 test data was reset, most likely. Nothing to transition;
                // ack so this doesn't loop forever on data that's gone.
                _logger.LogWarning("Received a result for unknown order {OrderId}; acking without action", orderId);
                await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
                return;
            }

            if (order.State == targetState)
            {
                // Redelivery of a result already applied -- idempotent no-op,
                // not an error. A full Inbox-pattern check (Week 9) will make
                // this exact case unambiguous by message id; for now, "already
                // in the state this message asks for" is a safe enough proxy.
                await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
                return;
            }

            order.TransitionTo(targetState);
            await dbContext.SaveChangesAsync();

            _logger.LogInformation("Order {OrderId} -> {State}", orderId, targetState);

            await _channel!.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
        }
        catch (InvalidOrderStateTransitionException ex)
        {
            // A genuine conflict (e.g. already Rejected, now told Reserved) --
            // not something a requeue will resolve, since the message's
            // instruction is fundamentally incompatible with the order's
            // actual state. Logged loudly rather than silently dropped or
            // retried forever; Week 10's DLQ gives this an actual home.
            _logger.LogError(ex, "Order state conflict processing a result event; dropping without requeue");
            await _channel!.BasicNackAsync(eventArgs.DeliveryTag, multiple: false, requeue: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process result event; requeueing");
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
