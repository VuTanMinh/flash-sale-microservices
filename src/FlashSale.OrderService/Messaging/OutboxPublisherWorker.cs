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
    private const int BatchSize = 50;

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
                // A full batch that all published means more rows are probably
                // waiting: go again at once instead of sleeping. Sleeping after
                // every batch capped publishing below BatchSize / PollInterval
                // (25 events/s), whatever the load (midterm review). The poll
                // interval now only applies when the Outbox is (nearly) empty or
                // a publish failed, so a broker outage still backs off.
                if (await PublishPendingEventsAsync(stoppingToken))
                {
                    continue;
                }
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

    /// <summary>
    /// Publishes up to BatchSize of the oldest unpublished rows. Returns true when
    /// the batch was full and every row published, i.e. the caller should run
    /// again at once rather than wait for the next poll.
    /// </summary>
    private async Task<bool> PublishPendingEventsAsync(CancellationToken stoppingToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
        var publisher = scope.ServiceProvider.GetRequiredService<IOutboxMessagePublisher>();

        await UpdateBacklogGaugesAsync(dbContext, stoppingToken);

        // The batch is claimed with FOR UPDATE SKIP LOCKED inside a transaction
        // that lasts until its rows are saved as published, so a second Order
        // Service instance would take other rows instead of publishing the same
        // ones (see Inventory Service's publisher, where C4 runs replicas).
        await using var transaction = await dbContext.Database.BeginTransactionAsync(stoppingToken);
        var pending = await dbContext.OutboxEvents
            .FromSqlRaw(
                "SELECT * FROM order_service.outbox_events WHERE \"Published\" = false " +
                "ORDER BY \"CreatedAt\" LIMIT {0} FOR UPDATE SKIP LOCKED", BatchSize)
            .ToListAsync(stoppingToken);

        var published = 0;
        if (pending.Count > 0)
        {
            // The whole batch goes out on one channel with its confirms
            // awaited together, then one save marks every confirmed row
            // (midterm review: a channel and a save per row capped the drain at
            // a few dozen events/s). A crash after the confirms but before the
            // save sends the batch again; consumers drop the repeats by
            // MessageId, the same at-least-once contract as before.
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

            // Rows the batch could not publish get the per-message retry with
            // backoff, oldest first. The first one that still fails ends this
            // poll, so a broker outage costs one row's backoff, not the
            // batch's; the rest wait for the next poll.
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
                var retriedAt = await TryPublishWithRetryAsync(publisher, pending[i].EventType, pending[i].Payload, pending[i].Id, stoppingToken);
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
