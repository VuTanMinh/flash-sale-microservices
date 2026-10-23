namespace FlashSale.OrderService.Messaging;

/// <summary>
/// C3 application-level admission control (Week 12 boxes 1 and 2). Bound from
/// the "Admission" appsettings section. Off by default, so C2 (today's
/// behaviour) is unchanged until a C3 configuration turns it on.
/// </summary>
public class AdmissionOptions
{
    public bool Enabled { get; set; } = false;

    public int MaxConcurrentNewOrders { get; set; } = 64;

    /// <summary>
    /// Week 12 box 2: the maximum number of unpublished rows the Order Outbox
    /// may hold before a new order is refused with 503 (reason="backlog").
    /// Default 0 = the bound is off. Only consulted when Enabled is true; read
    /// from <see cref="OutboxBacklogMonitor"/> (the worker's last measured count
    /// plus the orders accepted since), never a per-request count(*). See
    /// docs/load-shedding.md.
    /// </summary>
    public int MaxOutboxBacklog { get; set; } = 0;

    /// <summary>
    /// The maximum number of orders accepted but not yet Completed or Rejected
    /// before a new order is refused with 503 (reason="inflight"). Default 0 =
    /// off. Only consulted when Enabled is true; read from
    /// <see cref="InFlightOrdersMonitor"/> (measured every
    /// <see cref="InFlightRefreshMilliseconds"/> plus the orders accepted
    /// since). Added after the external review of Week 12: the Outbox bound
    /// alone let work pile up behind the slow Process Worker.
    /// </summary>
    public int MaxInFlightOrders { get; set; } = 0;

    public int InFlightRefreshMilliseconds { get; set; } = 1000;
}
