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
    private readonly OutboxBacklogMonitor _backlogMonitor;

    public OutboxPublisherWorker(
        IServiceScopeFactory scopeFactory, ILogger<OutboxPublisherWorker> logger, OutboxBacklogMonitor backlogMonitor)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _backlogMonitor = backlogMonitor;
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

        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);

        var pending = await dbContext.OutboxEvents
            .Where(e => !e.Published)
            .OrderBy(e => e.CreatedAt)
            .Take(50)
            .ToListAsync(stoppingToken);

        foreach (var outboxEvent in pending)
        {
            var sentAt = await TryPublishWithRetryAsync(publisher, outboxEvent.EventType, outboxEvent.Payload, outboxEvent.Id, stoppingToken);
            if (sentAt is not null)
            {
                outboxEvent.MarkPublished(sentAt.Value);
                await dbContext.SaveChangesAsync(stoppingToken);
            }
        }

        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);
    }

    /// <summary>
    /// Week 11 (TP-P04): the Outbox backlog as Prometheus gauges -- every
    /// unpublished row (not just this poll's batch of 50) and the age of the
    /// oldest one in seconds (0 when the Outbox is empty). Refreshed at the
    /// start and end of every poll.
    ///
    /// Week 12 box 2: the same count is also published to
    /// <see cref="OutboxBacklogMonitor"/> so the admission gate can read it
    /// without a per-request count(*) -- one computation feeds both the gauge
    /// and the admission bound.
    /// </summary>
    private async Task UpdateBacklogGaugesAsync(OrderServiceDbContext dbContext, CancellationToken stoppingToken)
    {
        // Snapshot the accepted counter before the count query, so Publish clears
        // only the accepts this query is about to see and does not lose an order
        // accepted while the query ran (Week 12 box 2, review R1).
        var acceptedSnapshot = _backlogMonitor.SnapshotAccepted();
        var unpublished = dbContext.OutboxEvents.Where(e => !e.Published);
        var count = await unpublished.CountAsync(stoppingToken);
        var oldest = count == 0 ? (DateTime?)null : await unpublished.MinAsync(e => (DateTime?)e.CreatedAt, stoppingToken);
        OutboxMetrics.Unpublished.Set(count);
        OutboxMetrics.OldestUnpublishedAgeSeconds.Set(oldest is null ? 0 : Math.Max(0, (DateTime.UtcNow - oldest.Value).TotalSeconds));
        _backlogMonitor.Publish(count, acceptedSnapshot);
    }

    /// <summary>
    /// Returns when the attempt that the broker confirmed was sent, or null
    /// when every attempt failed (see OutboxEvent.MarkPublished for why the
    /// send time, not the confirm time, is what gets recorded).
    /// </summary>
    private async Task<DateTime?> TryPublishWithRetryAsync(
        IOutboxMessagePublisher publisher, string eventType, string payload, Guid outboxEventId, CancellationToken stoppingToken)
    {
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                var sentAt = DateTime.UtcNow;
                await publisher.PublishAsync(eventType, payload, stoppingToken);
                return sentAt;
            }
            catch (Exception ex)
            {
                if (attempt == MaxAttempts)
                {
                    _logger.LogError(
                        ex,
                        "Failed to publish outbox event {OutboxEventId} after {Attempts} attempts; leaving unpublished, will retry on the next poll",
                        outboxEventId, attempt);
                    return null;
                }

                var delay = RetryDelays[attempt - 1];
                _logger.LogWarning(
                    ex,
                    "Failed to publish outbox event {OutboxEventId} (attempt {Attempt}/{MaxAttempts}); retrying in {Delay}",
                    outboxEventId, attempt, MaxAttempts, delay);
                await Task.Delay(delay, stoppingToken);
            }
        }

        return null;
    }
}
