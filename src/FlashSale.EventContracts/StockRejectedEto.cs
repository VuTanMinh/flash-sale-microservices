using System;
using Volo.Abp.EventBus;

namespace FlashSale.EventContracts;

/// <summary>
/// Published by Inventory Service (Week 8) after the Redis Lua reservation
/// script (Week 7) returns REJECTED (out of stock). Consumed by Order Service
/// to transition PendingStock -> Rejected (docs/order-state-machine.md).
///
/// No Reason field: the only rejection cause in scope is insufficient stock
/// (docs/00-scope-lock.md excludes payment failure and other rejection
/// causes), so there is nothing for a Reason field to distinguish yet — add
/// one only when a second real cause actually exists, per the checklist's
/// own warning against fields added "just in case".
/// </summary>
[EventName("FlashSale.InventoryService.StockRejected")]
public class StockRejectedEto
{
    public Guid OrderId { get; set; }

    public string ProductId { get; set; } = null!;

    public Guid MessageId { get; set; }
}
