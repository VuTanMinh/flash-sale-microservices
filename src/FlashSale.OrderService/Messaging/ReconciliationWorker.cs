using System;
using System.Collections.Concurrent;
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
/// PendingStock past a configurable timeout (and, since the review after
/// Week 12, in Confirmed or Processing; see WhereStuck) and re-triggers processing --
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
///
/// Week 10 box 2 bounds that re-ask: after Reconciliation:MaxAttempts
/// re-triggers (counted from the OrderPlaced rows themselves, so the bound
/// survives a restart) an order is given up on -- but only once the last
/// re-trigger has had its full timeout window, so the alert never fires while a
/// re-trigger is still in flight. A given-up order is logged as an Error,
/// exposed via Prometheus metrics as unresolved, and left PendingStock, never
/// invented as Rejected. The Error is logged once per process lifetime; after
/// an Order Service restart it is logged once more for a still-stuck order (the
/// dedup set is per process), which is acceptable -- it is a fresh alert. The
/// recovery of a *known* outcome (a result Inventory already published but
/// Order Service lost) is handled on the Inventory side: a re-triggered
/// OrderPlaced makes Inventory re-send its stored result rather than change
/// anything here (see OrderPlacedProcessor).
/// </summary>
public class ReconciliationWorker : BackgroundService
{
    private readonly ReconciliationOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<ReconciliationWorker> _logger;

    /// <summary>
    /// Orders whose "given up" Error has already been logged this process
    /// lifetime. The attempt count itself lives in the database (the number of
    /// OrderPlaced rows), so it survives a restart; this set only stops the
    /// same order's Error from being logged on every subsequent poll tick. The
    /// set is pruned every tick (an order that later leaves PendingStock is
    /// removed), and it is per-process: after an Order Service restart the set
    /// is empty, so a still-stuck order's Error is logged once more -- that is
    /// acceptable, and intended, as a fresh alert.
    /// </summary>
    private readonly ConcurrentDictionary<Guid, byte> _givenUpLogged = new();

    public ReconciliationWorker(
        IOptions<ReconciliationOptions> options, IServiceScopeFactory scopeFactory, ILogger<ReconciliationWorker> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogInformation("Reconciliation is disabled (Reconciliation:Enabled = false)");
            return;
        }

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

        var now = DateTime.UtcNow;
        var stuckOrders = await WhereStuck(dbContext.Orders, now, _options).ToListAsync(stoppingToken);

        OrderMetrics.ReconciliationStuckOrders.Set(stuckOrders.Count);

        // Prune the "already alerted" set every tick: an order that has since
        // left PendingStock (for example Inventory came back and its queued
        // OrderPlaced was consumed) is no longer stuck, so remove it -- the set
        // must not grow without bound over the process lifetime.
        var stuckOrderIds = stuckOrders.Select(o => o.Id).ToHashSet();
        foreach (var alertedId in _givenUpLogged.Keys.ToList())
        {
            if (!stuckOrderIds.Contains(alertedId))
            {
                _givenUpLogged.TryRemove(alertedId, out _);
            }
        }

        foreach (var order in stuckOrders)
        {
            // The attempt count is derived from the OrderPlaced outbox rows:
            // the row written at creation is the original delivery, and every
            // further row is one reconciliation re-trigger. Deriving it (rather
            // than storing a counter) is what makes the bound survive an Order
            // Service restart -- the rows are in the database, so a restarted
            // worker resumes from the same count instead of resetting it.
            var orderPlacedRows = await dbContext.OutboxEvents
                .Where(e => e.OrderId == order.Id && e.EventType == "OrderPlaced")
                .ToListAsync(stoppingToken);

            var pastRetriggers = ReconciliationPolicy.PastRetriggers(orderPlacedRows.Count);
            var stuckTimeout = StuckTimeout(order.State, _options);
            var recentlyRetriggered = orderPlacedRows.Any(e => e.CreatedAt >= now - stuckTimeout);

            switch (ReconciliationPolicy.Decide(pastRetriggers, recentlyRetriggered, _options.MaxAttempts))
            {
                case ReconciliationPolicy.Decision.GivenUp:
                    // Week 10 box 2: stop re-triggering and surface the order as
                    // unresolved. The state is deliberately NOT changed (no
                    // invented Rejected): the order genuinely has no outcome yet,
                    // and the operator must look at why (Inventory down, a lost
                    // result, ...). Logged once per process lifetime; the gauge
                    // above keeps reporting the order as stuck on every tick.
                    if (_givenUpLogged.TryAdd(order.Id, 0))
                    {
                        OrderMetrics.ReconciliationGivenUp.Inc();
                        _logger.LogError(
                            "Reconciliation: order {OrderId} still {State} after {Attempts} re-triggers (age {Age}); giving up and surfacing as unresolved",
                            order.Id, order.State, pastRetriggers, DateTime.UtcNow - order.RequestAcceptedAt);
                    }
                    break;

                case ReconciliationPolicy.Decision.ReTrigger:
                    OrderMetrics.ReconciliationRetriggers.Inc();
                    _logger.LogWarning(
                        "Reconciliation: order {OrderId} stuck in {State} for over {Timeout} (accepted {RequestAcceptedAt}); re-publishing OrderPlaced (re-trigger {Attempt}/{MaxAttempts})",
                        order.Id, order.State, stuckTimeout, order.RequestAcceptedAt, pastRetriggers + 1, _options.MaxAttempts);

                    dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));
                    await dbContext.SaveChangesAsync(stoppingToken);
                    break;

                case ReconciliationPolicy.Decision.RecentlyReTriggered:
                    // Within this state's timeout of the last re-trigger -- wait
                    // for the next full timeout window before acting again.
                    break;
            }
        }
    }

    /// <summary>
    /// Which orders count as stuck at <paramref name="now"/>. PendingStock is
    /// timed from acceptance (no stock decision yet). Confirmed and Processing
    /// are timed from the stock confirmation, against the longer
    /// ProcessingStuckTimeoutSeconds: the Worker's StockReserved, start event
    /// or completion was lost. The same re-trigger recovers both cases,
    /// because Inventory answers a repeated OrderPlaced by re-sending its
    /// stored StockReserved, which reaches the Process Worker again (see
    /// OrderPlacedProcessor). Terminal states are never stuck.
    /// </summary>
    public static IQueryable<Order> WhereStuck(IQueryable<Order> orders, DateTime now, ReconciliationOptions options)
    {
        var pendingCutoff = now - StuckTimeout(OrderState.PendingStock, options);
        var processingCutoff = now - StuckTimeout(OrderState.Processing, options);
        return orders.Where(o =>
            (o.State == OrderState.PendingStock && o.RequestAcceptedAt < pendingCutoff) ||
            ((o.State == OrderState.Confirmed || o.State == OrderState.Processing) && o.ConfirmedOrRejectedAt < processingCutoff));
    }

    // A Confirmed/Processing order is never treated as stuck sooner than a
    // PendingStock one: it has already passed the PendingStock stage. This also
    // keeps StuckTimeoutSeconds as the one switch that turns reconciliation off
    // (every verifier that does not test it sets 3600).
    private static TimeSpan StuckTimeout(OrderState state, ReconciliationOptions options) =>
        TimeSpan.FromSeconds(state == OrderState.PendingStock
            ? options.StuckTimeoutSeconds
            : Math.Max(options.ProcessingStuckTimeoutSeconds, options.StuckTimeoutSeconds));
}
