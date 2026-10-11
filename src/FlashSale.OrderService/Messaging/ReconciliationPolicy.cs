using System;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// The pure decision logic behind <see cref="ReconciliationWorker"/>'s bounded
/// re-trigger (Week 10 box 2), extracted from the worker so it can be exercised
/// directly by a unit test without a broker or a database -- the same reason
/// <see cref="StockResultProcessor"/> was extracted (Week 9).
///
/// "Attempts" here counts *re-triggers*, not deliveries: the OrderPlaced row
/// written at order creation is the original delivery, not a re-trigger, so an
/// order with N OrderPlaced rows has been re-triggered N-1 times.
/// Reconciliation stops (gives up, and the order is surfaced as unresolved)
/// once the re-trigger count reaches MaxAttempts AND the last re-trigger is no
/// longer recent (it has had its full timeout window to take effect) -- it
/// never changes the order's state (no invented <c>Rejected</c>).
/// </summary>
public static class ReconciliationPolicy
{
    /// <summary>The next action ReconciliationWorker should take for one stuck order.</summary>
    public enum Decision
    {
        /// <summary>Insert another OrderPlaced outbox row (a re-trigger).</summary>
        ReTrigger,

        /// <summary>Do nothing this tick: a re-trigger was already written within the timeout window.</summary>
        RecentlyReTriggered,

        /// <summary>Stop re-triggering: the bound is reached and the last re-trigger is no longer recent; surface the order as unresolved.</summary>
        GivenUp,
    }

    /// <summary>
    /// How many times an order with <paramref name="orderPlacedRowCount"/>
    /// OrderPlaced outbox rows has already been re-triggered: every row after
    /// the first (the original delivery written at creation) is one re-trigger.
    /// </summary>
    public static int PastRetriggers(int orderPlacedRowCount) =>
        Math.Max(0, orderPlacedRowCount - 1);

    /// <summary>
    /// Decides the next reconciliation action for one stuck order.
    /// </summary>
    public static Decision Decide(int pastRetriggers, bool recentlyRetriggered, int maxAttempts)
    {
        // A recent re-trigger wins over the bound: give up only once the last
        // re-trigger has had its full timeout window to take effect. Otherwise
        // the alert would fire on the tick right after the final re-trigger,
        // while that re-trigger is still in flight.
        if (recentlyRetriggered)
        {
            return Decision.RecentlyReTriggered;
        }

        if (pastRetriggers >= maxAttempts)
        {
            return Decision.GivenUp;
        }

        return Decision.ReTrigger;
    }
}
