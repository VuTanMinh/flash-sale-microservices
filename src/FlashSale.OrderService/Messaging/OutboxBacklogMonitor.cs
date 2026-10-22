using System.Threading;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Week 12 box 2 (C3): a singleton that estimates the Order Outbox unpublished
/// count for the admission gate without a per-request count(*). It combines the
/// last count the <see cref="OutboxPublisherWorker"/> measured with the orders
/// this process has accepted since that measurement, so the gate reflects a
/// newly-accepted order immediately instead of waiting for the next poll (which,
/// with the broker down, can stretch to minutes because of the per-message
/// retry ladder).
/// </summary>
public sealed class OutboxBacklogMonitor
{
    private int _published;             // last unpublished count measured by the worker
    private int _acceptedSinceRefresh;  // orders accepted since the last measurement

    /// <summary>
    /// The current estimate: the last measured count plus every order accepted
    /// since that measurement. Before the first poll both are 0, so an unknown
    /// backlog is treated as admit (the concurrency gate still applies).
    /// </summary>
    public int Unpublished =>
        Volatile.Read(ref _published) + Interlocked.CompareExchange(ref _acceptedSinceRefresh, 0, 0);

    /// <summary>
    /// Called by the controller once a NEW order and its Outbox row are saved
    /// (the 201 path only — never on an idempotent replay or the unique-violation
    /// race that returns the existing order).
    /// </summary>
    public void RecordAccepted() => Interlocked.Increment(ref _acceptedSinceRefresh);

    /// <summary>
    /// Called by the worker BEFORE its count query. The returned value is passed
    /// back to <see cref="Publish"/> so only the accepts that query was about to
    /// see are cleared, and an order accepted while the query ran is not lost
    /// from the estimate.
    /// </summary>
    public int SnapshotAccepted() => Interlocked.CompareExchange(ref _acceptedSinceRefresh, 0, 0);

    /// <summary>
    /// Records a fresh measured count. <paramref name="acceptedSnapshot"/> is the
    /// value <see cref="SnapshotAccepted"/> returned before the count query ran.
    /// </summary>
    public void Publish(int count, int acceptedSnapshot)
    {
        Volatile.Write(ref _published, count);
        Interlocked.Add(ref _acceptedSinceRefresh, -acceptedSnapshot);
    }
}
