using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.ExceptionServices;
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
///
/// Midterm review (throughput): one confirm channel is kept open and reused,
/// instead of opening a channel, declaring the exchange and checking the
/// routing for every single message, and a batch's publishes are all sent
/// before their confirms are awaited. Each message is still confirmed on its
/// own; only the waiting overlaps. A channel that saw any failure is closed
/// and the next call opens a fresh one.
/// </summary>
public class RabbitMqOutboxPublisher : IOutboxMessagePublisher, IDisposable
{
    private readonly RabbitMqOptions _options;
    private readonly ILogger<RabbitMqOutboxPublisher> _logger;
    private readonly SemaphoreSlim _connectionLock = new(1, 1);
    private readonly SemaphoreSlim _channelLock = new(1, 1);
    private IConnection? _connection;
    private IChannel? _channel;

    public RabbitMqOutboxPublisher(IOptions<RabbitMqOptions> options, ILogger<RabbitMqOutboxPublisher> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public async Task PublishAsync(string eventType, string payloadJson, CancellationToken cancellationToken = default)
    {
        var failure = (await PublishBatchAsync([new OutboxMessage(eventType, payloadJson)], cancellationToken))[0];
        if (failure is not null)
        {
            ExceptionDispatchInfo.Throw(failure);
        }
    }

    public async Task<Exception?[]> PublishBatchAsync(IReadOnlyList<OutboxMessage> messages, CancellationToken cancellationToken = default)
    {
        var failures = new Exception?[messages.Count];
        if (messages.Count == 0)
        {
            return failures;
        }

        await _channelLock.WaitAsync(cancellationToken);
        try
        {
            IChannel channel;
            try
            {
                channel = await GetOrCreateChannelAsync(cancellationToken);
                foreach (var eventType in messages.Select(m => m.EventType).Distinct())
                {
                    await AssertRequiredRoutingAsync(channel, eventType, cancellationToken);
                }
            }
            catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
            {
                // No connection, or a required queue is missing (the passive
                // declare also closes the channel): nothing in the batch is sent.
                await DropChannelAsync();
                Array.Fill(failures, ex);
                return failures;
            }

            // Routing key = event type (e.g. "OrderPlaced") -- Inventory Service
            // (Week 7) binds its queue to this exchange with that routing key.
            // Each ValueTask completes only when RabbitMQ has acknowledged that
            // message (confirmation tracking above); they are started in order
            // and awaited afterwards. See MarkPublished's own doc comment on
            // OutboxEvent for why the confirm is what matters.
            var exchangeName = _options.EventBus.ExchangeName;
            var confirms = new ValueTask[messages.Count];
            for (var i = 0; i < messages.Count; i++)
            {
                try
                {
                    confirms[i] = channel.BasicPublishAsync(
                        exchangeName,
                        messages[i].EventType,
                        mandatory: true,
                        basicProperties: CreateProperties(messages[i].EventType),
                        body: Encoding.UTF8.GetBytes(messages[i].PayloadJson),
                        cancellationToken: cancellationToken);
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
                {
                    failures[i] = ex;
                }
            }

            for (var i = 0; i < messages.Count; i++)
            {
                if (failures[i] is not null)
                {
                    continue;
                }

                try
                {
                    await confirms[i];
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
                {
                    failures[i] = ex;
                }
            }

            if (failures.Any(f => f is not null) || !channel.IsOpen)
            {
                await DropChannelAsync();
            }

            return failures;
        }
        finally
        {
            _channelLock.Release();
        }
    }

    private static BasicProperties CreateProperties(string eventType) => new()
    {
        Persistent = true,
        ContentType = "application/json",
        Type = eventType,
        // Stamp the publish time so RabbitMQ's head_message_timestamp can
        // report the oldest-message age (Week 11 milestone, Task A).
        Timestamp = new AmqpTimestamp(DateTimeOffset.UtcNow.ToUnixTimeSeconds()),
    };

    /// <summary>
    /// Routed-confirmation rule (docs/outbox.md): before publishing, assert
    /// that every subscriber queue this event REQUIRES exists (passive
    /// declare -- throws if missing, so the publish fails and is retried
    /// instead of silently reaching nobody) and is bound. Binding is
    /// idempotent; asserting it here means a removed binding cannot make
    /// one required subscriber (e.g. the Process Worker for StockReserved)
    /// miss a message that another subscriber still receives. Checked once
    /// per event type per batch.
    /// </summary>
    private async Task AssertRequiredRoutingAsync(IChannel channel, string eventType, CancellationToken cancellationToken)
    {
        if (!_options.EventBus.RequiredSubscriberQueues.TryGetValue(eventType, out var requiredQueues) || requiredQueues.Length == 0)
        {
            throw new InvalidOperationException($"No required subscriber queues configured for event '{eventType}'; refusing to publish unchecked.");
        }

        foreach (var queue in requiredQueues)
        {
            await channel.QueueDeclarePassiveAsync(queue, cancellationToken);
            await channel.QueueBindAsync(queue, _options.EventBus.ExchangeName, eventType, cancellationToken: cancellationToken);
        }
    }

    private async Task<IChannel> GetOrCreateChannelAsync(CancellationToken cancellationToken)
    {
        if (_channel is { IsOpen: true })
        {
            return _channel;
        }

        await DropChannelAsync();

        var connection = await GetOrCreateConnectionAsync(cancellationToken);
        var channelOptions = new CreateChannelOptions(
            publisherConfirmationsEnabled: true,
            publisherConfirmationTrackingEnabled: true);
        var channel = await connection.CreateChannelAsync(channelOptions, cancellationToken: cancellationToken);
        try
        {
            await channel.ExchangeDeclareAsync(
                _options.EventBus.ExchangeName, ExchangeType.Direct, durable: true, autoDelete: false,
                cancellationToken: cancellationToken);
        }
        catch
        {
            await channel.DisposeAsync();
            throw;
        }

        _channel = channel;
        return channel;
    }

    private async Task DropChannelAsync()
    {
        var channel = _channel;
        _channel = null;
        if (channel is null)
        {
            return;
        }

        try
        {
            await channel.DisposeAsync();
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Ignoring an error while closing a failed publish channel");
        }
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
        _channel?.Dispose();
        _connection?.Dispose();
        _connectionLock.Dispose();
        _channelLock.Dispose();
    }
}
