using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Polls order_service.outbox_events for unpublished rows and publishes each
/// to RabbitMQ, marking a row published only once IOutboxMessagePublisher's
/// await has actually returned -- i.e. only after a broker-confirmed publish
/// (checklist Step 6.2). A bounded retry-with-backoff runs per message so a
/// transient broker hiccup doesn't crash the whole worker; a message that
/// keeps failing past that just stays unpublished and gets picked up again
/// on the next poll, rather than being dropped.
/// </summary>
public class OutboxPublisherWorker : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
    ];
    private const int MaxAttempts = 4; // 1 initial + 3 retries, per RetryDelays above

    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<OutboxPublisherWorker> _logger;

    public OutboxPublisherWorker(IServiceScopeFactory scopeFactory, ILogger<OutboxPublisherWorker> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await PublishPendingEventsAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A failure here means something broke outside the per-message
                // retry loop below (e.g. the database itself is unreachable) --
                // log it and try again next tick rather than letting one bad
                // tick take the whole background worker down.
                _logger.LogError(ex, "Outbox publisher tick failed unexpectedly");
            }

            try
            {
                await Task.Delay(PollInterval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
        }
    }

    private async Task PublishPendingEventsAsync(CancellationToken stoppingToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
        var publisher = scope.ServiceProvider.GetRequiredService<IOutboxMessagePublisher>();

        var pending = await dbContext.OutboxEvents
            .Where(e => !e.Published)
            .OrderBy(e => e.CreatedAt)
            .Take(50)
            .ToListAsync(stoppingToken);

        foreach (var outboxEvent in pending)
        {
            var published = await TryPublishWithRetryAsync(publisher, outboxEvent.EventType, outboxEvent.Payload, outboxEvent.Id, stoppingToken);
            if (published)
            {
                outboxEvent.MarkPublished();
                await dbContext.SaveChangesAsync(stoppingToken);
            }
        }
    }

    private async Task<bool> TryPublishWithRetryAsync(
        IOutboxMessagePublisher publisher, string eventType, string payload, Guid outboxEventId, CancellationToken stoppingToken)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                await publisher.PublishAsync(eventType, payload, stoppingToken);
                return true;
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex,
                        "Failed to publish outbox event {OutboxEventId} after {Attempts} attempts; leaving unpublished, will retry on the next poll",
                        outboxEventId, attempt);
                    return false;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to publish outbox event {OutboxEventId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    outboxEventId, attempt, MaxAttempts, delay);
                await Task.Delay(delay, stoppingToken);
            }
        }

        return false;
    }
}
