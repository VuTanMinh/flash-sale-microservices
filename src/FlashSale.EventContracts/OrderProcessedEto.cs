using System;
using Volo.Abp.EventBus;

namespace FlashSale.EventContracts;

/// <summary>
/// Published by the Process Worker (Week 11) after its deterministic
/// downstream-processing delay elapses. Consumed by Order Service to
/// transition Confirmed -> Completed (docs/order-state-machine.md).
///
/// No Result/Success field: the Process Worker simulates downstream
/// processing with a deterministic *success* outcome only (Proposal §3,
/// and docs/00-scope-lock.md excludes payment failure and compensation).
/// A success flag with exactly one possible value is not information --
/// add one the day a second outcome actually exists, per the same reasoning
/// that keeps StockRejectedEto free of a Reason field.
///
/// No ProductId either: the only thing Order Service does with this event
/// is close out the order it names, and it already knows that order's
/// product.
/// </summary>
[EventName("FlashSale.ProcessWorker.OrderProcessed")]
public class OrderProcessedEto
{
    public Guid OrderId { get; set; }

    /// <summary>
    /// Deliberately set equal to <see cref="OrderId"/>, not to a fresh Guid
    /// like every other event in this contract. Step 11.1 specifies that the
    /// Process Worker "uses order_id as its own idempotency key", and the
    /// Process Worker is the one service here with no database of its own to
    /// record what it has already handled (see its own README/doc comment for
    /// why it needs none). Deriving the MessageId from the order id instead
    /// means a redelivered StockReserved produces a byte-identical
    /// OrderProcessed, which Order Service's Week 9 Inbox then dedupes with
    /// no extra machinery -- the idempotency key travels in the message
    /// rather than living in a store.
    /// </summary>
    public Guid MessageId { get; set; }

    /// <summary>
    /// Carried through from the StockReserved event that triggered this one,
    /// which in turn carried it from OrderPlaced -- see Week 11's
    /// correlation-ID propagation (Step 11.2).
    /// </summary>
    public string CorrelationId { get; set; } = null!;
}
