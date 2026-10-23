using System.Threading;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// A count the admission gate reads without a per-request count(*) (Week 12
/// box 2, C3): the last value a background measurement published plus every
/// order this process has accepted since. The gate therefore sees a newly
/// accepted order immediately instead of waiting for the next measurement.
/// Shared by <see cref="OutboxBacklogMonitor"/> (unpublished Outbox rows) and
/// <see cref="InFlightOrdersMonitor"/> (orders not yet Completed or Rejected).
/// </summary>
public abstract class AdmissionCountEstimate
{
    private int _measured;              // last count published by the measurement
    private int _acceptedSinceRefresh;  // orders accepted since that measurement

    /// <summary>
    /// The current estimate. Before the first measurement both parts are 0, so
    /// an unknown count is treated as admit (the concurrency gate still applies).
    /// </summary>
    protected int Current =>
        Volatile.Read(ref _measured) + Interlocked.CompareExchange(ref _acceptedSinceRefresh, 0, 0);

    /// <summary>
    /// Called by the controller once a NEW order is saved (the 201 path only,
    /// never on an idempotent replay or the unique-violation race that returns
    /// the existing order).
    /// </summary>
    public void RecordAccepted() => Interlocked.Increment(ref _acceptedSinceRefresh);

    /// <summary>
    /// Called by the measurement BEFORE its count query. The returned value is
    /// passed back to <see cref="Publish"/> so only the accepts that query was
    /// about to see are cleared, and an order accepted while the query ran is
    /// not lost from the estimate.
    /// </summary>
    public int SnapshotAccepted() => Interlocked.CompareExchange(ref _acceptedSinceRefresh, 0, 0);

    /// <summary>
    /// Records a fresh measured count. <paramref name="acceptedSnapshot"/> is the
    /// value <see cref="SnapshotAccepted"/> returned before the count query ran.
    /// </summary>
    public void Publish(int count, int acceptedSnapshot)
    {
        Volatile.Write(ref _measured, count);
        Interlocked.Add(ref _acceptedSinceRefresh, -acceptedSnapshot);
    }
}
