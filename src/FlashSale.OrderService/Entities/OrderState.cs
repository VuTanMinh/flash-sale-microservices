namespace FlashSale.OrderService.Entities;

/// <summary>
/// Matches docs/order-state-machine.md exactly.
///
/// Week 11 update: Processing and ProcessingFailed were REMOVED from this
/// enum, not merely left unreachable. The Week 1 draft declared them because
/// the Process Worker's design was still an open question; now that it is
/// built (Step 11.1), neither state has a trigger that the system can
/// actually observe:
///
///   * Processing -- the Process Worker consumes the same StockReserved
///     event Order Service does and publishes exactly one completion event.
///     Order Service therefore learns two facts about an order ("stock
///     reserved", "processing finished") and never a third one in between.
///     Inventing a second "processing started" event purely to make this
///     state reachable would add a contract, a queue, a consumer and an
///     inbox path to a simulator, for a state no reader of the order would
///     act on. Where the work actually is mid-flight is already observable
///     where it genuinely lives: the Process Worker's own queue depth.
///   * ProcessingFailed -- the Process Worker's result is deterministically
///     successful by design (Proposal §3), and docs/00-scope-lock.md
///     excludes payment failure and compensation, so nothing in scope can
///     produce this outcome. A state no code path can reach is a claim the
///     system does not keep.
///
/// Keeping either one as a declared-but-dead value would have left exactly
/// the kind of aspirational-diagram gap this project has refused elsewhere.
/// </summary>
public enum OrderState
{
    PendingStock,
    Confirmed,
    Rejected,
    Completed,
}
