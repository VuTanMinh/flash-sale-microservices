using System;
using System.Text;
using System.Text.Json;
using FlashSale.EventContracts;
using Microsoft.Extensions.Options;
using RabbitMQ.Client;

namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Publishes OrderProcessingStarted with publisher confirmations enabled and
/// tracked, exactly like <see cref="OrderProcessedPublisher"/> (see that class's
/// doc comment for the no-Outbox reasoning). The Worker publishes the start
/// event when it begins work on a reserved order, BEFORE its deterministic
/// delay, so Order Service observes the Confirmed -> Processing transition
/// instead of guessing (docs/order-state-machine.md).
/// </summary>
public class OrderProcessingStartedPublisher : IDisposable
{
    private readonly RabbitMqOptions _options;
    private readonly ILogger<OrderProcessingStartedPublisher> _logger;
    private readonly SemaphoreSlim _connectionLock = new(1, 1);
    private IConnection? _connection;

    public OrderProcessingStartedPublisher(IOptions<RabbitMqOptions> options, ILogger<OrderProcessingStartedPublisher> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task PublishAsync(OrderProcessingStartedEto orderProcessingStarted, CancellationToken cancellationToken = default)
    {
        var connection = await GetOrCreateConnectionAsync(cancellationToken);

        var channelOptions = new CreateChannelOptions(
            publisherConfirmationsEnabled: true,
            publisherConfirmationTrackingEnabled: true);

        await using var channel = await connection.CreateChannelAsync(channelOptions, cancellationToken: cancellationToken);

        var exchangeName = _options.EventBus.ExchangeName;
        await channel.ExchangeDeclareAsync(
            exchangeName, ExchangeType.Direct, durable: true, autoDelete: false, cancellationToken: cancellationToken);

        // Routed-confirmation rule (docs/outbox.md): assert every required
        // subscriber queue exists and is bound before publishing (see
        // OrderProcessedPublisher for the fuller reasoning).
        if (!_options.EventBus.RequiredSubscriberQueues.TryGetValue("OrderProcessingStarted", out var requiredQueues) || requiredQueues.Length == 0)
        {
            throw new InvalidOperationException($"No required subscriber queues configured for event '{"OrderProcessingStarted"}'; refusing to publish unchecked.");
        }

        foreach (var queue in requiredQueues)
        {
            await channel.QueueDeclarePassiveAsync(queue, cancellationToken);
            await channel.QueueBindAsync(queue, exchangeName, "OrderProcessingStarted", cancellationToken: cancellationToken);
        }

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = "OrderProcessingStarted",
            // Stamp the publish time so RabbitMQ's head_message_timestamp can
            // report the oldest-message age (Week 11 milestone, Task A).
            Timestamp = new AmqpTimestamp(DateTimeOffset.UtcNow.ToUnixTimeSeconds()),
        };

        var body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(orderProcessingStarted));

        await channel.BasicPublishAsync(
            exchangeName,
            routingKey: "OrderProcessingStarted",
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
