using System.Text;
using System.Text.Json;
using FlashSale.EventContracts;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Publishes OrderProcessed with publisher confirmations enabled and
/// tracked, so the BasicPublishAsync await itself is the broker's
/// acknowledgement -- the same choice, for the same reason, as both other
/// services' outbox publishers (Week 6/8).
///
/// There is no Outbox behind this one, and that is not an inconsistency.
/// An Outbox exists to stop a local business write and a publish from
/// disagreeing when only one of them succeeds. This service performs no
/// local write at all: it waits, then publishes. The only failure mode left
/// is "published or not published", and the caller handles that by not
/// acking the input message until the publish is confirmed -- so a crash
/// anywhere in the sequence simply replays it.
/// </summary>
public class OrderProcessedPublisher : IDisposable
{
    private readonly RabbitMqOptions _options;
    private readonly ILogger<OrderProcessedPublisher> _logger;
    private readonly SemaphoreSlim _connectionLock = new(1, 1);
    private IConnection? _connection;

    public OrderProcessedPublisher(IOptions<RabbitMqOptions> options, ILogger<OrderProcessedPublisher> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task PublishAsync(OrderProcessedEto orderProcessed, CancellationToken cancellationToken = default)
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
            Type = "OrderProcessed",
        };

        var body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(orderProcessed));

        await channel.BasicPublishAsync(
            exchangeName,
            routingKey: "OrderProcessed",
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
