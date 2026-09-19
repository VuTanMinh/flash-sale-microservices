using Prometheus;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// The order-lifecycle metrics Week 13/14 actually measure against, exposed
/// on /metrics for Prometheus (Step 11.3). Deliberately a small, fixed set
/// rather than "instrument everything": each one below answers a question
/// the Experimental Design chapter already commits to asking.
///
/// Note what is NOT here. Request latency percentiles (p50/p95/p99) are not
/// computed in-process: JMeter measures client-observed latency directly
/// (Week 3's smoke test already does), and the end-to-end pipeline latency
/// is reconstructed from the per-order timestamp schema (Proposal §4d) in
/// Postgres. A Prometheus histogram of the same thing would be a third,
/// lower-resolution copy of a number two better sources already have --
/// and, being bucketed, would disagree with them at the tail, which is
/// exactly where this project's research question lives.
/// </summary>
public static class OrderMetrics
{
    public static readonly Counter OrdersAccepted = Metrics.CreateCounter(
        "flashsale_orders_accepted_total",
        "Orders accepted by POST /api/orders (state PendingStock), before any stock decision.");

    /// <summary>
    /// One counter with a label rather than three counters: Week 13/14 read
    /// these as a ratio (how much of the offered load each configuration
    /// confirms vs. rejects vs. completes), and a label makes that a single
    /// PromQL expression instead of an arithmetic join across metric names.
    /// </summary>
    public static readonly Counter OrdersByOutcome = Metrics.CreateCounter(
        "flashsale_orders_outcome_total",
        "Order state transitions applied by this service's consumers.",
        new CounterConfiguration { LabelNames = ["outcome"] });
}
