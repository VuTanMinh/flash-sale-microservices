using Prometheus;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Order Service's Outbox backlog gauges (Week 11 box 3). Updated on every
/// OutboxPublisherWorker poll so Prometheus can see the unpublished backlog --
/// and the age of the oldest unpublished row -- even while the broker is down
/// and the publish attempt below keeps failing. A gauge, not a counter: the
/// number an operator alerts on is "how many are stuck right now", not the
/// cumulative history of failed publishes.
/// </summary>
public static class OutboxMetrics
{
    public static readonly Gauge Unpublished = Metrics.CreateGauge(
        "flashsale_outbox_unpublished",
        "Outbox rows not yet published to the broker.");

    public static readonly Gauge OldestUnpublishedAgeSeconds = Metrics.CreateGauge(
        "flashsale_outbox_oldest_unpublished_age_seconds",
        "Age in seconds of the oldest unpublished outbox row; 0 when the outbox is empty.");
}
