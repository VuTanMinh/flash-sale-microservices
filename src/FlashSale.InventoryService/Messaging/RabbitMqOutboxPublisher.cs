using System;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Same design and same reasoning as Order Service's RabbitMqOutboxPublisher
/// (Week 6): raw RabbitMQ.Client with publisher confirmations enabled and
/// tracked, so the BasicPublishAsync await itself is the broker confirm --
/// not Volo.Abp.EventBus.RabbitMQ, whose options don't expose a documented
/// way to enable that.
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

        // Routed-confirmation rule (docs/outbox.md): before publishing, assert
        // that every subscriber queue this event REQUIRES exists (passive
        // declare -- throws if missing, so the publish fails and is retried
        // instead of silently reaching nobody) and is bound. Binding is
        // idempotent; asserting it here means a removed binding cannot make
        // one required subscriber (e.g. the Process Worker for StockReserved)
        // miss a message that another subscriber still receives.
        if (!_options.EventBus.RequiredSubscriberQueues.TryGetValue(eventType, out var requiredQueues) || requiredQueues.Length == 0)
        {
            throw new InvalidOperationException($"No required subscriber queues configured for event '{eventType}'; refusing to publish unchecked.");
        }

        foreach (var queue in requiredQueues)
        {
            await channel.QueueDeclarePassiveAsync(queue, cancellationToken);
            await channel.QueueBindAsync(queue, exchangeName, eventType, cancellationToken: cancellationToken);
        }

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = eventType,
        };

        var body = Encoding.UTF8.GetBytes(payloadJson);

        await channel.BasicPublishAsync(
            exchangeName,
            eventType,
            mandatory: true,
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
                "Connecting to RabbitMQ at {HostName}:{Port}", factory.HostName, factory.Port);

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
