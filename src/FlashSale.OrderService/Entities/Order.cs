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

    /// <summary>
    /// Week 11 (Step 11.2). Minted at this order's entry point, or taken from
    /// the caller's X-Correlation-ID header, then carried unchanged onto every
    /// event this order causes. Stored on the order itself (not only in logs)
    /// so a row in the database can still be tied back to its request trace
    /// after the fact -- which is what Week 13/14 need when reconciling
    /// measured latencies against what the logs say happened.
    /// </summary>
    public string CorrelationId { get; private set; } = null!;

    /// <summary>When the order was accepted (this is also the "created" timestamp — a
    /// separate generic CreatedAt would just duplicate it).</summary>
    public DateTime RequestAcceptedAt { get; private set; }

    public DateTime? ConfirmedOrRejectedAt { get; private set; }

    public DateTime? CompletedAt { get; private set; }

    private Order()
    {
        // EF Core materialization only.
    }

    public Order(Guid id, string idempotencyKey, string productId, int quantity, string correlationId)
    {
        Id = id;
        IdempotencyKey = idempotencyKey;
        ProductId = productId;
        Quantity = quantity;
        CorrelationId = correlationId;
        State = OrderState.PendingStock;
        RequestAcceptedAt = DateTime.UtcNow;
    }

    /// <summary>
    /// docs/order-state-machine.md, transcribed directly. Week 11 closed the
    /// open question that kept Confirmed terminal through Weeks 5-10: the
    /// Process Worker consumes StockReserved, waits its deterministic delay,
    /// and publishes exactly one OrderProcessed, which drives
    /// Confirmed -> Completed here.
    ///
    /// That single completion event is also why Processing and
    /// ProcessingFailed no longer exist as states at all (see OrderState):
    /// with one input event and one output event, this service never learns
    /// a distinct "processing has begun" fact to transition ON, and the
    /// scope lock rules out the failure path that ProcessingFailed existed
    /// for. Both were retired rather than left declared-but-unreachable.
    /// </summary>
    private static readonly Dictionary<OrderState, OrderState[]> LegalTransitions = new()
    {
        [OrderState.PendingStock] = [OrderState.Confirmed, OrderState.Rejected],
        [OrderState.Confirmed] = [OrderState.Completed],
        [OrderState.Rejected] = [],
        [OrderState.Completed] = [],
    };

    public void TransitionTo(OrderState newState)
    {
        if (!LegalTransitions.TryGetValue(State, out var allowed) || !allowed.Contains(newState))
        {
            throw new InvalidOrderStateTransitionException(State, newState);
        }

        State = newState;

        // The timestamp schema from Proposal §4d is recorded by these two
        // assignments plus RequestAcceptedAt in the constructor; the fourth
        // stage (event publication) is already timestamped on the order's own
        // outbox row (outbox_events.published_at, joinable by order_id) and is
        // deliberately NOT copied here -- doing so would add a second write to
        // the publish path of a system whose throughput is the thing under
        // measurement.
        if (newState is OrderState.Confirmed or OrderState.Rejected)
        {
            ConfirmedOrRejectedAt = DateTime.UtcNow;
        }
        else if (newState is OrderState.Completed)
        {
            CompletedAt = DateTime.UtcNow;
        }
    }
}
