namespace FlashSale.OrderService.Entities;

/// <summary>
/// Matches docs/order-state-machine.md exactly. Two transitions out of
/// Confirmed/Processing (Confirmed->Processing, Processing->Completed/
/// ProcessingFailed) are still an open question there pending the Week 11
/// Process Worker design -- the states exist here because the checklist asks
/// for the full enum now, but nothing in this service can reach them yet
/// (see Order.LegalTransitions).
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
