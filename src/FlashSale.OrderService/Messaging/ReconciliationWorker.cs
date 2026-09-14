using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Step 10.3's safety net: periodically scans for orders stuck in
/// PendingStock past a configurable timeout and re-triggers processing --
/// nothing more. Proposal §5 is explicit that this is a safety net, not a
/// replacement for Outbox (Week 6), retry (Step 10.1), or DLQ (Step 10.2):
/// under normal operation this should almost never find anything, since
/// those three mechanisms already cover the ordinary failure modes. Finding
/// something here means one of them didn't hold -- which is exactly why
/// every intervention is logged at Warning, not swallowed quietly (this
/// project's own explicit warning against a silent second path that masks
/// real Outbox/retry bugs; a high intervention rate in Week 13/14 is itself
/// meant to be a visible experimental result, not background noise).
///
/// "Re-trigger processing" here means: insert a fresh OrderPlaced outbox row
/// for the order, with a brand-new MessageId. This is deliberately NOT a
/// direct call into Inventory Service, nor a queue purge/repair -- Order
/// Service has no access to Inventory Service's own schema (docs/erd.md's
/// schema-per-service boundary), so the only thing this service can
/// legitimately do with its own data is ask the pipeline to run again from
/// the top. That re-ask is safe specifically because Weeks 7-9 already made
/// every downstream step idempotent: Redis's order-level dedup (Week 7),
/// Inventory Service's ensure-exists outbox (Week 8), and this service's own
/// Inbox (Week 9) all mean a genuine duplicate in-flight message converges
/// to the same one-time effect as the original, rather than double-applying.
/// </summary>
public class ReconciliationWorker : BackgroundService
{
    private readonly ReconciliationOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<ReconciliationWorker> _logger;

    public ReconciliationWorker(
        IOptions<ReconciliationOptions> options, IServiceScopeFactory scopeFactory, ILogger<ReconciliationWorker> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var pollInterval = TimeSpan.FromSeconds(_options.PollIntervalSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ReconcileStuckOrdersAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Same "one bad tick shouldn't kill the whole worker" reasoning
                // as OutboxPublisherWorker (Week 6) -- try again next poll.
                _logger.LogError(ex, "Reconciliation tick failed unexpectedly");
            }

            try
            {
                await Task.Delay(pollInterval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
        }
    }

    private async Task ReconcileStuckOrdersAsync(CancellationToken stoppingToken)
    {
        using var scope = _scopeFactory.CreateScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();

        var stuckTimeout = TimeSpan.FromSeconds(_options.StuckTimeoutSeconds);
        var cutoff = DateTime.UtcNow - stuckTimeout;

        var stuckOrders = await dbContext.Orders
            .Where(o => o.State == OrderState.PendingStock && o.RequestAcceptedAt < cutoff)
            .ToListAsync(stoppingToken);

        foreach (var order in stuckOrders)
        {
            // Don't re-trigger an order within StuckTimeoutSeconds of its last
            // re-trigger -- caps how often this fires for one order at once
            // per timeout window, rather than on literally every poll tick.
            // Confirmed live (Step 10.2's poison-message test, which leaves a
            // permanently-stuck order behind on purpose): an order that is
            // STILL stuck after a re-trigger gets re-triggered again once the
            // next full timeout window elapses, and keeps doing so for as
            // long as it stays stuck -- this is intended, not a runaway loop.
            // A message that recovers quickly (the normal case a transient
            // hiccup) simply leaves PendingStock before the next tick and
            // stops matching the query above; only a genuinely still-broken
            // order keeps getting picked up, at this bounded, loudly-logged
            // cadence -- which is exactly the "high intervention rate is
            // itself an important result" signal this step's own warning
            // calls for, not something to suppress.
            var recentlyRetriggered = await dbContext.OutboxEvents.AnyAsync(
                e => e.OrderId == order.Id && e.EventType == "OrderPlaced" && e.CreatedAt >= cutoff,
                stoppingToken);

            if (recentlyRetriggered)
            {
                continue;
            }

            _logger.LogWarning(
                "Reconciliation: order {OrderId} stuck in PendingStock for over {Timeout} (accepted {RequestAcceptedAt}); re-publishing OrderPlaced",
                order.Id, stuckTimeout, order.RequestAcceptedAt);

            dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));
            await dbContext.SaveChangesAsync(stoppingToken);
        }
    }
}
