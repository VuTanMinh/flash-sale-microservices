using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.InventoryService.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Same design as Order Service's OutboxPublisherWorker (Week 6): polls
/// unpublished rows, publishes with a bounded retry-with-backoff, marks
/// published only after a broker-confirmed publish. See that class for the
/// fuller reasoning; this is Inventory Service's own copy, draining its own
/// outbox_events table (StockReserved/StockRejected, not OrderPlaced).
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
    private const int MaxAttempts = 4;

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
                _logger.LogError(ex, "Outbox publisher tick failed unexpectedly");
            }

            try
            {
                await Task.Delay(PollInterval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private async Task PublishPendingEventsAsync(CancellationToken stoppingToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<InventoryServiceDbContext>();
        var publisher = scope.ServiceProvider.GetRequiredService<IOutboxMessagePublisher>();

        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);

        var pending = await dbContext.OutboxEvents
            .Where(e => !e.Published)
            .OrderBy(e => e.CreatedAt)
            .Take(50)
            .ToListAsync(stoppingToken);

        foreach (var outboxEvent in pending)
        {
            var sentAt = await TryPublishWithRetryAsync(
                publisher, outboxEvent.EventType, outboxEvent.Payload, outboxEvent.Id, stoppingToken);
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
    /// </summary>
    private static async Task UpdateBacklogGaugesAsync(InventoryServiceDbContext dbContext, CancellationToken stoppingToken)
    {
        var unpublished = dbContext.OutboxEvents.Where(e => !e.Published);
        var count = await unpublished.CountAsync(stoppingToken);
        var oldest = count == 0 ? (DateTime?)null : await unpublished.MinAsync(e => (DateTime?)e.CreatedAt, stoppingToken);
        InventoryMetrics.Unpublished.Set(count);
        InventoryMetrics.OldestUnpublishedAgeSeconds.Set(oldest is null ? 0 : Math.Max(0, (DateTime.UtcNow - oldest.Value).TotalSeconds));
    }

    /// <summary>
    /// Returns when the attempt that the broker confirmed was sent, or null
    /// when every attempt failed (see OutboxEvent.MarkPublished).
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
