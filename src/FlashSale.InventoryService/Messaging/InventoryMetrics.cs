using Prometheus;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Inventory Service's own business and Outbox metrics (Week 11 box 3).
///
/// StockDecisions counts each Lua reservation call that actually committed
/// (i.e. was not skipped by an Inbox hit), labelled by the reserve.lua outcome
/// (reserved / rejected / not_open / duplicate). A retry that re-runs the Lua
/// script and gets DUPLICATE therefore increments the <c>duplicate</c> series,
/// which is what Week 13/14 needs to tell a re-delivered message apart from a
/// fresh reservation.
///
/// The two gauges are Inventory Service's Outbox backlog, updated on every
/// OutboxPublisherWorker poll (see Order Service's OutboxMetrics for the fuller
/// reasoning).
/// </summary>
public static class InventoryMetrics
{
    public static readonly Counter StockDecisions = Metrics.CreateCounter(
        "flashsale_stock_decisions_total",
        "Committed Lua reservation calls, labelled by outcome.",
        new CounterConfiguration { LabelNames = ["outcome"] });

    public static readonly Gauge Unpublished = Metrics.CreateGauge(
        "flashsale_outbox_unpublished",
        "Outbox rows not yet published to the broker.");

    public static readonly Gauge OldestUnpublishedAgeSeconds = Metrics.CreateGauge(
        "flashsale_outbox_oldest_unpublished_age_seconds",
        "Age in seconds of the oldest unpublished outbox row; 0 when the outbox is empty.");

    /// <summary>Creates every decision outcome at 0 so all four are exported from start-up.</summary>
    public static void Initialize()
    {
        foreach (var outcome in new[] { "reserved", "rejected", "not_open", "duplicate" })
        {
            StockDecisions.WithLabels(outcome);
        }
    }
}
