using System;
using System.Collections.Generic;
using System.Linq;

namespace FlashSale.OrderService.Entities;

/// <summary>
/// The real Order aggregate (Week 5) — distinct from the raw-SQL
/// order_service.baseline_orders table the C0/C1 experiments use
/// (docs/erd.md). Plain class, not an ABP AggregateRoot: AggregateRoot's
/// audit properties (CreatorId, LastModifierId, ...) are tied to ABP's
/// Identity/User system, and re-coupling to that would cut against the
/// Week 4 finding that Identity isn't actually part of this project's scope.
/// </summary>
public class Order
{
    public Guid Id { get; private set; }

    /// <summary>
    /// Client-supplied idempotency key (the "Idempotency-Key" header) — dedupes
    /// duplicate *client* submissions. NOT the same as the broker-message-level
    /// MessageId on the ETOs in FlashSale.EventContracts (Week 9 Inbox pattern,
    /// dedupes duplicate *delivery*) — see docs/00-scope-lock.md's boundary note.
    /// </summary>
    public string IdempotencyKey { get; private set; } = null!;

    public string ProductId { get; private set; } = null!;

    public int Quantity { get; private set; }

    public OrderState State { get; private set; }

    /// <summary>When the order was accepted (this is also the "created" timestamp — a
    /// separate generic CreatedAt would just duplicate it).</summary>
    public DateTime RequestAcceptedAt { get; private set; }

    public DateTime? ConfirmedOrRejectedAt { get; private set; }

    public DateTime? CompletedAt { get; private set; }

    private Order()
    {
        // EF Core materialization only.
    }

    public Order(Guid id, string idempotencyKey, string productId, int quantity)
    {
        Id = id;
        IdempotencyKey = idempotencyKey;
        ProductId = productId;
        Quantity = quantity;
        State = OrderState.PendingStock;
        RequestAcceptedAt = DateTime.UtcNow;
    }

    /// <summary>
    /// docs/order-state-machine.md, transcribed directly. Confirmed->Processing
    /// and Processing->Completed/ProcessingFailed are deliberately absent: that
    /// document records their trigger as an open question pending the Week 11
    /// Process Worker design, so there is nothing here for this service to
    /// legally transition into yet — adding them now would mean guessing a
    /// mechanism instead of waiting for the actual design.
    /// </summary>
    private static readonly Dictionary<OrderState, OrderState[]> LegalTransitions = new()
    {
        [OrderState.PendingStock] = [OrderState.Confirmed, OrderState.Rejected],
        [OrderState.Confirmed] = [],
        [OrderState.Rejected] = [],
        [OrderState.Processing] = [],
        [OrderState.Completed] = [],
        [OrderState.ProcessingFailed] = [],
    };

    public void TransitionTo(OrderState newState)
    {
        if (!LegalTransitions.TryGetValue(State, out var allowed) || !allowed.Contains(newState))
        {
            throw new InvalidOrderStateTransitionException(State, newState);
        }

        State = newState;

        if (newState is OrderState.Confirmed or OrderState.Rejected)
        {
            ConfirmedOrRejectedAt = DateTime.UtcNow;
        }
    }
}
