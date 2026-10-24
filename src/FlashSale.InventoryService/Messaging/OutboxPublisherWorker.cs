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
    private const int BatchSize = 50;

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
                // Same rule as Order Service's publisher: after a full batch
                // that all published, go again at once; sleep only when the
                // Outbox is (nearly) empty or a publish failed (midterm review).
                if (await PublishPendingEventsAsync(stoppingToken))
                {
                    continue;
                }
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

    /// <summary>
    /// Publishes up to BatchSize of the oldest unpublished rows. Returns true when
    /// the batch was full and every row published.
    /// </summary>
    private async Task<bool> PublishPendingEventsAsync(CancellationToken stoppingToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<InventoryServiceDbContext>();
        var publisher = scope.ServiceProvider.GetRequiredService<IOutboxMessagePublisher>();

        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);

        // C4 runs several Inventory replicas, each with this publisher. The
        // batch is claimed with FOR UPDATE SKIP LOCKED inside a transaction that
        // lasts until its rows are saved as published, so two replicas never
        // pick the same rows: the other replica skips them and takes the next
        // ones. Without the lock every replica published every row (midterm
        // review), which multiplied the broker traffic and the Worker's work.
        await using var transaction = await dbContext.Database.BeginTransactionAsync(stoppingToken);
        var pending = await dbContext.OutboxEvents
            .FromSqlRaw(
                "SELECT * FROM inventory_service.outbox_events WHERE \"Published\" = false " +
                "ORDER BY \"CreatedAt\" LIMIT {0} FOR UPDATE SKIP LOCKED", BatchSize)
            .ToListAsync(stoppingToken);

        // Same batching as Order Service's publisher (midterm review): one
        // channel and one save for the batch, then the per-message retry for
        // whatever the batch could not publish, stopping at the first row that
        // still fails.
        var published = 0;
        if (pending.Count > 0)
        {
            var sentAt = DateTime.UtcNow;
            var failures = await publisher.PublishBatchAsync(
                pending.Select(e => new OutboxMessage(e.EventType, e.Payload)).ToList(), stoppingToken);
            for (var i = 0; i < pending.Count; i++)
            {
                if (failures[i] is null)
                {
                    pending[i].MarkPublished(sentAt);
                    published++;
                }
            }

            await dbContext.SaveChangesAsync(stoppingToken);

            for (var i = 0; i < pending.Count; i++)
            {
                if (failures[i] is null)
                {
                    continue;
                }

                _logger.LogWarning(
                    failures[i],
                    "Failed to publish outbox event {OutboxEventId} in its batch; retrying it on its own",
                    pending[i].Id);
                var retriedAt = await TryPublishWithRetryAsync(
                    publisher, pending[i].EventType, pending[i].Payload, pending[i].Id, stoppingToken);
                if (retriedAt is null)
                {
                    break;
                }

                pending[i].MarkPublished(retriedAt.Value);
                await dbContext.SaveChangesAsync(stoppingToken);
                published++;
            }
        }

        await transaction.CommitAsync(stoppingToken);
        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);
        return pending.Count == BatchSize && published == pending.Count;
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
