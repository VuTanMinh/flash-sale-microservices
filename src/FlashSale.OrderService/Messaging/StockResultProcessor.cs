using System;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.EntityFrameworkCore;

namespace FlashSale.OrderService.Messaging;

public enum ResultProcessingOutcome
{
    /// <summary>The order was actually transitioned this call.</summary>
    Applied,

    /// <summary>
    /// No transition happened, but not an error: either this exact MessageId
    /// was already recorded in the Inbox (redelivery of the same broker
    /// message), the order was already in the target state (redelivery via a
    /// different code path, e.g. before Week 9 existed), or this call lost a
    /// database-level race to a concurrent identical delivery. All three are
    /// "someone already handled this" -- safe to ack in every case.
    /// </summary>
    AlreadyProcessed,

    /// <summary>The order id on the message doesn't exist -- ack, nothing to transition.</summary>
    OrderNotFound,
}

/// <summary>
/// The idempotent core of Step 8.2/9.2, extracted out of
/// <see cref="StockResultConsumer"/> so it can be exercised directly by a
/// test (Step 9.4) without needing a live RabbitMQ broker -- the broker
/// plumbing around this (ack/nack, deserialization) has no correctness logic
/// of its own worth testing in isolation; this does.
///
/// Note what "process, then insert the Inbox row in the same transaction"
/// (Step 9.2's own wording) means concretely here: both the order's state
/// write and the ProcessedMessage insert are tracked on the same DbContext
/// and committed by one SaveChangesAsync call, so a crash between them is
/// impossible by construction -- either both happened, or neither did.
/// </summary>
public static class StockResultProcessor
{
    /// <summary>Production entry point -- always saves via the real, DI-backed SaveChangesAsync.</summary>
    public static Task<ResultProcessingOutcome> ProcessAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType, OrderState targetState) =>
        ProcessAsync(dbContext, orderId, messageId, eventType, targetState, () => dbContext.SaveChangesAsync());

    /// <summary>
    /// Same logic, with the save call injectable. Exists only so a test
    /// (Step 9.4) can substitute AbpDbContext's SaveChangesOnDbContextAsync
    /// bypass for the real SaveChangesAsync -- the latter needs a full ABP DI
    /// scope (audit logging, event dispatch) that a directly-constructed
    /// DbContext in a test doesn't have, the same documented limitation
    /// OutboxAtomicityTests already works around. Production code (the
    /// overload above) always uses the real one.
    /// </summary>
    public static async Task<ResultProcessingOutcome> ProcessAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType, OrderState targetState,
        Func<Task<int>> saveChangesAsync)
    {
        var alreadyProcessed = await dbContext.ProcessedMessages.AnyAsync(m => m.MessageId == messageId);
        if (alreadyProcessed)
        {
            return ResultProcessingOutcome.AlreadyProcessed;
        }

        var order = await dbContext.Orders.FirstOrDefaultAsync(o => o.Id == orderId);
        if (order is null)
        {
            return ResultProcessingOutcome.OrderNotFound;
        }

        if (IsAtOrPast(order.State, targetState))
        {
            // Same state (a duplicate with a new MessageId) or a stale event
            // for a state the order has already moved past on the happy path
            // (e.g. StockReserved arriving after Completed): acknowledge as a
            // no-op, per docs/order-state-machine.md "Delivery rules".
            // Order.TransitionTo has no legal self-loop for Confirmed/Rejected
            // (Order.cs's LegalTransitions table) -- calling it here would
            // throw InvalidOrderStateTransitionException on a legitimate
            // redelivery, not report a real conflict. Still record the Inbox
            // row so a future redelivery of this exact MessageId short-circuits
            // at the check above instead of re-running this comparison.
            dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));
            try
            {
                await saveChangesAsync();
            }
            catch (DbUpdateException)
            {
                // Lost a race to a concurrent delivery of the same message; it
                // already recorded this Inbox row. Nothing further to do.
            }

            return ResultProcessingOutcome.AlreadyProcessed;
        }

        // A genuine conflict (e.g. already Rejected, now told Reserved) throws
        // InvalidOrderStateTransitionException here and propagates to the
        // caller uncaught -- that is a real error, not an idempotency case,
        // and the caller (StockResultConsumer) nacks it without requeue.
        order.TransitionTo(targetState);
        dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));

        try
        {
            await saveChangesAsync();
        }
        catch (DbUpdateException)
        {
            // Lost a race to a concurrent delivery of the exact same message
            // (unique constraint on MessageId) -- the winner already applied
            // this transition.
            return ResultProcessingOutcome.AlreadyProcessed;
        }

        return ResultProcessingOutcome.Applied;
    }

    // Happy-path progression for the "same or earlier state" rule. Rejected
    // is off the path: it only matches itself, so StockRejected after
    // Confirmed (or StockReserved after Rejected) stays a genuine conflict.
    private static readonly OrderState[] Progression =
        [OrderState.PendingStock, OrderState.Confirmed, OrderState.Completed];

    private static bool IsAtOrPast(OrderState current, OrderState target)
    {
        if (current == target)
        {
            return true;
        }

        var currentRank = Array.IndexOf(Progression, current);
        var targetRank = Array.IndexOf(Progression, target);
        return currentRank >= 0 && targetRank >= 0 && currentRank > targetRank;
    }
}
