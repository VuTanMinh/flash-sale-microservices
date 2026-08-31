using System;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Publishes via the raw RabbitMQ.Client, not Volo.Abp.EventBus.RabbitMQ's
/// IDistributedEventBus. This was a deliberate choice, made after checking
/// rather than assuming (per checklist Step 6.3's own warning): ABP's
/// AbpRabbitMqEventBusOptions / AbpRabbitMqOptions don't expose a documented
/// property for enabling publisher confirms. RabbitMQ.Client 7.x does, at
/// the channel level (CreateChannelOptions.PublisherConfirmationsEnabled) --
/// with confirmation tracking also enabled, BasicPublishAsync itself does
/// not complete until the broker has acknowledged the message. That await
/// completing successfully is what "the broker confirmed receipt" means
/// here; nothing about "the call didn't throw" alone would prove that.
/// </summary>
public class RabbitMqOutboxPublisher : IOutboxMessagePublisher, IDisposable
{
    private readonly RabbitMqOptions _options;
    private readonly ILogger<RabbitMqOutboxPublisher> _logger;
    private readonly SemaphoreSlim _connectionLock = new(1, 1);
    private IConnection? _connection;

    public RabbitMqOutboxPublisher(IOptions<RabbitMqOptions> options, ILogger<RabbitMqOutboxPublisher> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task PublishAsync(string eventType, string payloadJson, CancellationToken cancellationToken = default)
    {
        var connection = await GetOrCreateConnectionAsync(cancellationToken);

        var channelOptions = new CreateChannelOptions(
            publisherConfirmationsEnabled: true,
            publisherConfirmationTrackingEnabled: true);

        await using var channel = await connection.CreateChannelAsync(channelOptions, cancellationToken: cancellationToken);

        var exchangeName = _options.EventBus.ExchangeName;
        await channel.ExchangeDeclareAsync(
            exchangeName, ExchangeType.Direct, durable: true, autoDelete: false, cancellationToken: cancellationToken);

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = eventType,
        };

        var body = Encoding.UTF8.GetBytes(payloadJson);

        // Routing key = event type (e.g. "OrderPlaced") -- Inventory Service
        // (Week 7) binds its queue to this exchange with that routing key.
        // This await is the publisher confirm: with confirmation tracking
        // enabled above, it does not return until RabbitMQ has actually
        // acknowledged the message. See MarkPublished's own doc comment on
        // OutboxEvent for why that distinction matters.
        await channel.BasicPublishAsync(
            exchangeName,
            eventType,
            mandatory: false,
            basicProperties: properties,
            body: body,
            cancellationToken: cancellationToken);
    }

    private async Task<IConnection> GetOrCreateConnectionAsync(CancellationToken cancellationToken)
    {
        if (_connection is { IsOpen: true })
        {
            return _connection;
        }

        await _connectionLock.WaitAsync(cancellationToken);
        try
        {
            if (_connection is { IsOpen: true })
            {
                return _connection;
            }

            _connection?.Dispose();

            var factory = new ConnectionFactory
            {
                HostName = _options.Connections.Default.HostName,
                Port = _options.Connections.Default.Port,
                UserName = _options.Connections.Default.UserName,
                Password = _options.Connections.Default.Password,
            };

            _logger.LogInformation(
                "Connecting to RabbitMQ at {HostName}:{Port}",
                factory.HostName, factory.Port);

            _connection = await factory.CreateConnectionAsync(cancellationToken);
            return _connection;
        }
        finally
        {
            _connectionLock.Release();
        }
    }

    public void Dispose()
    {
        _connection?.Dispose();
        _connectionLock.Dispose();
    }
}
