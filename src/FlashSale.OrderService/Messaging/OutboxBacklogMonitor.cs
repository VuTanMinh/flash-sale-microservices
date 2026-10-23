namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Week 12 box 2 (C3): the Order Outbox unpublished count for the admission
/// gate. <see cref="OutboxPublisherWorker"/> publishes the measured count at
/// the start and end of every poll; between polls the estimate also includes
/// the orders accepted since, so the gate reflects a new order immediately
/// even when, with the broker down, a poll stretches to minutes because of the
/// per-message retry ladder. See <see cref="AdmissionCountEstimate"/>.
/// </summary>
public sealed class OutboxBacklogMonitor : AdmissionCountEstimate
{
    /// <summary>The current estimate of unpublished Order Outbox rows.</summary>
    public int Unpublished => Current;
}
