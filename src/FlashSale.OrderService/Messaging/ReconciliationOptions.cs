namespace FlashSale.OrderService.Messaging;

/// <summary>
/// Bound from the "Reconciliation" appsettings.json section. All three values
/// are deliberately configurable (not hardcoded) -- checklist Step 10.3's own
/// design note that this is a safety net, not a replacement for Outbox/retry/
/// DLQ, means how aggressively it intervenes is itself a tuning knob:
/// StuckTimeoutSeconds should sit comfortably above the normal happy-path
/// latency (a few seconds, per Weeks 7-8's own measured evidence) plus the
/// full Step 10.1 retry ladder (1s+2s+4s), so it only fires on orders that
/// are actually stuck, not ones merely mid-flight. MaxAttempts bounds how many
/// times one stuck order is re-triggered before it is given up on and surfaced
/// as unresolved (Week 10 box 2) -- "re-triggers", not "deliveries": the
/// OrderPlaced row written at creation is the original delivery and does not
/// count against the bound.
/// </summary>
public class ReconciliationOptions
{
    public int PollIntervalSeconds { get; set; } = 30;

    public int StuckTimeoutSeconds { get; set; } = 30;

    public int MaxAttempts { get; set; } = 3;

    /// <summary>
    /// How long an order may sit in Confirmed or Processing after its stock
    /// was confirmed before it counts as stuck (external review after Week 12:
    /// reconciliation used to watch PendingStock only, so an order whose
    /// Worker events were lost stayed Confirmed for ever). Longer than
    /// StuckTimeoutSeconds on purpose: the Process Worker's queue legitimately
    /// holds confirmed orders for about a minute after an overload (TP-L04),
    /// and re-triggering those would only make the Worker repeat its work.
    /// The effective value is never below StuckTimeoutSeconds.
    /// </summary>
    public int ProcessingStuckTimeoutSeconds { get; set; } = 300;
}
