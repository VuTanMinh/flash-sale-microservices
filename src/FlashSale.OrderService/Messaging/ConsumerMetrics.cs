using Prometheus;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Broker-consumer metrics shared by this service's three consumers
/// (StockResult, OrderProcessingStarted, OrderProcessed) -- Week 11 box 3.
///
/// The <c>consumer</c> label is low-cardinality by design (three fixed values
/// in this process), never an order/message id: ids belong in the logs, not in
/// metric labels (Notion 03C C-07). Each counter below answers one question
/// Week 13/14 asks under retry/duplicate/DLQ load:
///
///   Retries        -- one increment per retry wait inside a consumer's ladder;
///   Duplicates     -- one increment each time a message is acked as already
///                     processed (Inbox hit or the unique-violation race);
///   DeadLettered   -- one increment per message nacked to a DLQ, with the
///                     reason (exhausted / invalid / conflict);
///   RequeuedEarly  -- one increment per delayed requeue of an early Worker
///                     event (Week 9/11 bounded requeue).
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

    public static readonly Counter RequeuedEarly = Metrics.CreateCounter(
        "flashsale_consumer_requeued_early_total",
        "Early Worker events requeued onto a delayed retry queue.",
        new CounterConfiguration { LabelNames = ["consumer"] });

    /// <summary>
    /// One increment each time a state write lost to a concurrent transition
    /// and was decided again from a fresh read (StockResultProcessor). Not
    /// labelled: the processor does not know which consumer called it, and a
    /// non-zero count is the signal Week 13/14 need.
    /// </summary>
    public static readonly Counter StateConflicts = Metrics.CreateCounter(
        "flashsale_order_state_conflicts_total",
        "Order state writes that lost to a concurrent transition and were re-decided.");

    /// <summary>
    /// Creates this consumer's labelled series at 0 when it starts, so every
    /// series is exported from the first scrape (prometheus-net only exports a
    /// labelled child after it is created) and rate() works without gaps.
    /// </summary>
    public static void Initialize(string consumer, bool requeuesEarly = false)
    {
        Retries.WithLabels(consumer);
        Duplicates.WithLabels(consumer);
        foreach (var reason in new[] { "exhausted", "invalid", "conflict" })
        {
            DeadLettered.WithLabels(consumer, reason);
        }
        if (requeuesEarly)
        {
            RequeuedEarly.WithLabels(consumer);
        }
    }
}
