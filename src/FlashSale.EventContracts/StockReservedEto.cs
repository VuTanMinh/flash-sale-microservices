using System;
using Volo.Abp.EventBus;

namespace FlashSale.EventContracts;

/// <summary>
/// Published by Inventory Service (Week 8, via its own outbox-style pattern —
/// see checklist Step 8.1) after the Redis Lua reservation script
/// (scripts/redis/reserve.lua, Week 7) returns RESERVED. Consumed by Order
/// Service to transition PendingStock -> Confirmed (docs/order-state-machine.md).
/// </summary>
[EventName("FlashSale.InventoryService.StockReserved")]
public class StockReservedEto
{
    public Guid OrderId { get; set; }

    public string ProductId { get; set; } = null!;

    /// <summary>
    /// Broker-message-level idempotency key (Week 9 Inbox pattern) — this
    /// service's own copy, distinct from the message_id on the OrderPlaced
    /// event that triggered it.
    /// </summary>
    public Guid MessageId { get; set; }

    /// <summary>
    /// Copied verbatim from the OrderPlaced event that caused this
    /// reservation (Week 11, Step 11.2) — unlike MessageId, this is NOT
    /// regenerated per hop; that is the entire point of it.
    /// </summary>
    public string CorrelationId { get; set; } = null!;
}
