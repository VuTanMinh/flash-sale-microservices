namespace FlashSale.OrderService.Entities;

/// <summary>
/// The teacher's six named states, as adopted by the owners on 2026-10-01 and
/// transcribed in docs/order-state-machine.md: <see cref="PendingStock"/>,
/// <see cref="Confirmed"/>, <see cref="Rejected"/>, <see cref="Processing"/>,
/// <see cref="Completed"/>, <see cref="ProcessingFailed"/>.
///
/// Week 11 box 2 (TP-P02) promoted <see cref="Processing"/> from a declared-but-
/// absent value to a real, reachable state: the Process Worker publishes an
/// <c>OrderProcessingStarted</c> event when it begins work on a reserved order,
/// and Order Service observes it instead of guessing. The transition
/// <c>Confirmed → Completed</c> is now split into <c>Confirmed → Processing →
/// Completed</c>; an <c>OrderProcessed</c> that arrives while the order is still
/// <c>Confirmed</c> applies both legs in one transaction and records the
/// <c>Processing</c> history row as implied.
///
/// <see cref="ProcessingFailed"/> stays in the enum but is declared, not
/// reachable: the Process Worker's outcome is deterministically successful by
/// design (docs/00-scope-lock.md excludes payment failure and compensation), so
/// no event in scope produces it. It is kept so the model matches the teacher's
/// six states, and is documented as unreachable-by-design (success-only). It
/// becomes reachable only if a failing Worker outcome is added to scope with its
/// own event.
/// </summary>
public enum OrderState
{
    PendingStock,
    Confirmed,
    Rejected,
    Processing,
    Completed,
    ProcessingFailed,
}
