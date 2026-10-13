using Prometheus;

namespace FlashSale.InventoryService.Messaging;

/// <summary>
/// Broker-consumer metrics for Inventory Service's single consumer
/// (OrderPlaced) -- Week 11 box 3. Mirrors Order Service's ConsumerMetrics;
/// see that class for the fuller reasoning. The <c>consumer</c> label has one
/// fixed value in this process ("OrderPlaced"), never an id.
/// </summary>
public static class ConsumerMetrics
{
    public static readonly Counter Retries = Metrics.CreateCounter(
        "flashsale_consumer_retries_total",
        "Retry waits taken inside this service's consumer retry ladders.",
        new CounterConfiguration { LabelNames = ["consumer"] });

    public static readonly Counter Duplicates = Metrics.CreateCounter(
        "flashsale_consumer_duplicates_total",
        "Messages acked as already processed (Inbox hit or unique-violation race).",
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
        Duplicates.WithLabels(consumer);
        foreach (var reason in new[] { "exhausted", "invalid", "conflict" })
        {
            DeadLettered.WithLabels(consumer, reason);
        }
    }
}
