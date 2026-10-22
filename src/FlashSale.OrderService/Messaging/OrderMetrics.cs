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
    /// Admission rejections (Week 12 box 1, C3). Incremented only on the 503 a
    /// brand-new order gets when the admission gate is full -- never on an
    /// idempotent replay (those are answered before the gate). Counted apart
    /// from OrdersAccepted so Week 13/14 can read "admitted vs. refused at the
    /// gate" as a single ratio.
    /// </summary>
    public static readonly Counter AdmissionRejected = Metrics.CreateCounter(
        "flashsale_admission_rejected_total",
        "POST /api/orders requests refused at the admission gate (503), before any order is written.",
        new CounterConfiguration { LabelNames = ["reason"] });

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

    /// <summary>
    /// Reconciliation metrics (Week 10 box 2). A counter per action plus a
    /// gauge of the current backlog: the two counters answer "did the safety
    /// net fire, and did it give up on anything?", while the gauge answers
    /// "how many orders are stuck right now?" -- the number an operator alerts
    /// on, rather than the cumulative history the counters accumulate.
    /// </summary>
    public static readonly Counter ReconciliationRetriggers = Metrics.CreateCounter(
        "flashsale_reconciliation_retriggers_total",
        "OrderPlaced re-publishes issued by ReconciliationWorker for stuck PendingStock orders.");

    public static readonly Counter ReconciliationGivenUp = Metrics.CreateCounter(
        "flashsale_reconciliation_given_up_total",
        "Stuck PendingStock orders ReconciliationWorker stopped re-triggering after MaxAttempts.");

    public static readonly Gauge ReconciliationStuckOrders = Metrics.CreateGauge(
        "flashsale_reconciliation_stuck_orders",
        "Orders currently PendingStock past the reconciliation timeout.");

    /// <summary>
    /// Creates the labelled series at 0 so they are exported from the first
    /// /metrics scrape (prometheus-net exports a labelled child only after it
    /// is first created). Called once at startup, before any 503 is counted.
    /// </summary>
    public static void Initialize()
    {
        AdmissionRejected.WithLabels("concurrency");
        // Week 12 box 2: the Outbox-backlog refusal series, pre-created at 0 so
        // it is exported from the first /metrics scrape (same reason as the
        // "concurrency" series above).
        AdmissionRejected.WithLabels("backlog");
    }
}
