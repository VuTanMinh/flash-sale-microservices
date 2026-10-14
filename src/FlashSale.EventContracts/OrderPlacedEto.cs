using System;
using Volo.Abp.EventBus;

namespace FlashSale.EventContracts;

/// <summary>
/// Published by Order Service (via the Transactional Outbox, Week 6) when an
/// order is created and needs an inventory decision. Consumed by Inventory
/// Service (Week 7), which calls the Redis Lua reservation script and
/// responds with <see cref="StockReservedEto"/> or <see cref="StockRejectedEto"/>.
///
/// See docs/order-state-machine.md: this is the trigger for [*] -> PendingStock.
/// </summary>
[EventName("FlashSale.OrderService.OrderPlaced")]
public class OrderPlacedEto
{
    public Guid OrderId { get; set; }

    public string ProductId { get; set; } = null!;

    public int Quantity { get; set; }

    /// <summary>
    /// Broker-message-level idempotency key (Week 9 Inbox pattern) — set once
    /// at publish time. NOT the same as the client-supplied Idempotency-Key
    /// header from Week 5; see docs/00-scope-lock.md's boundary notes.
    /// </summary>
    public Guid MessageId { get; set; }

    /// <summary>
    /// Week 11 (Step 11.2). Minted at the Order Service entry point (or taken
    /// from the caller's X-Correlation-ID header) and carried unchanged
    /// through every event this order causes, so one grep across all three
    /// services' logs reconstructs the whole journey. Distinct from both
    /// MessageId (per-message, changes on every hop) and OrderId (business
    /// key): a correlation id identifies the *request*, and stays the same
    /// even where the order id isn't yet known to a log line.
    /// </summary>
    public string CorrelationId { get; set; } = null!;
}
