namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Bound from the "Reconciliation" appsettings.json section. Both values are
/// deliberately configurable (not hardcoded) -- checklist Step 10.3's own
/// design note that this is a safety net, not a replacement for Outbox/retry/
/// DLQ, means how aggressively it intervenes is itself a tuning knob:
/// StuckTimeoutSeconds should sit comfortably above the normal happy-path
/// latency (a few seconds, per Weeks 7-8's own measured evidence) plus the
/// full Step 10.1 retry ladder (1s+2s+4s), so it only fires on orders that
/// are actually stuck, not ones merely mid-flight.
/// </summary>
public class ReconciliationOptions
{
    public int PollIntervalSeconds { get; set; } = 30;

    public int StuckTimeoutSeconds { get; set; } = 30;
}
