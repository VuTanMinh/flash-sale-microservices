using Prometheus;

namespace FlashSale.ProcessWorker.Messaging;

/// <summary>
/// Broker-consumer metrics for the Process Worker's single consumer
/// (StockReserved) -- Week 11 box 3. Mirrors the other two services'
/// ConsumerMetrics; see Order Service's for the fuller reasoning.
///
/// The Worker has no Inbox, so there is no <c>Duplicates</c> series here: a
/// replayed StockReserved is always re-processed (re-publishing the derived
/// start and completion events, which Order Service's Inbox then absorbs).
/// </summary>
public static class ConsumerMetrics
{
    public static readonly Counter Retries = Metrics.CreateCounter(
        "flashsale_consumer_retries_total",
        "Retry waits taken inside this service's consumer retry ladders.",
        new CounterConfiguration { LabelNames = ["consumer"] });

    public static readonly Counter DeadLettered = Metrics.CreateCounter(
        "flashsale_consumer_dead_lettered_total",
        "Messages this service's consumers routed to a dead-letter queue.",
        new CounterConfiguration { LabelNames = ["consumer", "reason"] });

    /// <summary>
    /// Creates this consumer's labelled series at 0 when it starts, so every
    /// series is exported from the first scrape (prometheus-net only exports a
    /// labelled child after it is created) and rate() works without gaps.
    /// </summary>
    public static void Initialize(string consumer)
    {
        Retries.WithLabels(consumer);
        foreach (var reason in new[] { "exhausted", "invalid", "conflict" })
        {
            DeadLettered.WithLabels(consumer, reason);
        }
    }
}
