using System;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.EntityFrameworkCore;
using Npgsql;

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

    /// <summary>
    /// The event arrived before the event it depends on: a Worker event
    /// (<c>OrderProcessingStarted</c>, target <see cref="OrderState.Processing"/>,
    /// or <c>OrderProcessed</c>, target <see cref="OrderState.Completed"/>) for an
    /// order still in <see cref="OrderState.PendingStock"/>, because Inventory
    /// Service's <c>StockReserved</c> has not been applied yet -- the Process
    /// Worker consumes the same event in parallel, so under backlog the Worker's
    /// events can genuinely win the race.
    ///
    /// This is deliberately NOT an error and NOT a no-op. It is not an error
    /// because nothing is wrong: the transition is still owed, the order is
    /// simply behind. It is not a no-op because the transition has not happened:
    /// writing an Inbox row or transitioning here would either lose the event or
    /// invent a state change the state machine does not allow. So nothing is
    /// written at all, and the caller requeues the message for a bounded retry
    /// instead of dead-lettering it (docs/design-decisions.md section 2).
    /// </summary>
    NotYetApplicable,
}

/// <summary>
/// The idempotent core of Step 8.2/9.2/11.2, extracted out of the consumers so
/// it can be exercised directly by a test without a live RabbitMQ broker.
/// <see cref="StockResultConsumer"/> applies single-transition stock results
/// (Confirmed/Rejected), <see cref="OrderProcessingStartedConsumer"/> applies the
/// start event (Processing), and <see cref="OrderProcessedConsumer"/> applies the
/// completion (Completed, or the implied Confirmed → Processing → Completed).
///
/// Every applied transition writes an <see cref="OrderStatusHistory"/> row in
/// the SAME transaction as the state write and the Inbox insert (one
/// SaveChangesAsync call), so a crash between them is impossible by construction
/// -- either all happened, or none did. A no-op writes no history row.
/// </summary>
public static class StockResultProcessor
{
    /// <summary>Production entry point for single-transition events -- always saves via the real, DI-backed SaveChangesAsync.</summary>
    public static Task<ResultProcessingOutcome> ProcessAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType, OrderState targetState) =>
        ProcessAsync(dbContext, orderId, messageId, eventType, targetState, () => dbContext.SaveChangesAsync());

    /// <summary>
    /// Same logic, with the save call injectable. Exists only so a test can
    /// substitute AbpDbContext's SaveChangesOnDbContextAsync bypass for the real
    /// SaveChangesAsync -- see OutboxAtomicityTests for the same documented
    /// limitation. Production code (the overload above) always uses the real one.
    /// </summary>
    public static Task<ResultProcessingOutcome> ProcessAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType, OrderState targetState,
        Func<Task<int>> saveChangesAsync) =>
        RetryOnStateConflictAsync(dbContext,
            () => ProcessOnceAsync(dbContext, orderId, messageId, eventType, targetState, saveChangesAsync));

    private static async Task<ResultProcessingOutcome> ProcessOnceAsync(
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

        if (IsAwaitingPrerequisite(order.State, targetState))
        {
            // A Worker event for an order whose StockReserved has not been
            // applied yet (see NotYetApplicable). Checked before the
            // IsAtOrPast no-op rule below, which would otherwise classify it
            // as "already past" -- Processing/Completed outrank PendingStock on
            // the happy path, but the order has not travelled that path yet.
            return ResultProcessingOutcome.NotYetApplicable;
        }

        if (IsAtOrPast(order.State, targetState))
        {
            // Same state (a duplicate with a new MessageId) or a stale event
            // for a state the order has already moved past on the happy path
            // (e.g. StockReserved arriving after Completed): acknowledge as a
            // no-op, per docs/order-state-machine.md "Delivery rules". No
            // history row is written for a no-op. Still record the Inbox row so
            // a future redelivery of this exact MessageId short-circuits at the
            // check above instead of re-running this comparison.
            dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));
            try
            {
                await saveChangesAsync();
            }
            catch (DbUpdateException ex) when (IsUniqueViolation(ex))
            {
                // Lost a race to a concurrent delivery of the same message; it
                // already recorded this Inbox row. Nothing further to do.
            }

            return ResultProcessingOutcome.AlreadyProcessed;
        }

        // A genuine conflict (e.g. already Rejected, now told Reserved) throws
        // InvalidOrderStateTransitionException here and propagates to the
        // caller uncaught -- that is a real error, not an idempotency case, and
        // the caller nacks it without requeue.
        var from = order.State;
        order.TransitionTo(targetState);
        dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
            Guid.NewGuid(), orderId, from, targetState, messageId, TransitionTime(order, targetState), implied: false));
        dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));

        try
        {
            await saveChangesAsync();
        }
        catch (DbUpdateException ex) when (IsUniqueViolation(ex))
        {
            // Lost a race to a concurrent delivery of the exact same message
            // (unique constraint on MessageId) -- the winner already applied
            // this transition (and its history row).
            return ResultProcessingOutcome.AlreadyProcessed;
        }

        return ResultProcessingOutcome.Applied;
    }

    /// <summary>Production entry point for the completion event -- always saves via the real, DI-backed SaveChangesAsync.</summary>
    public static Task<ResultProcessingOutcome> ProcessCompletionAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType, DateTime? processingStartedAt) =>
        ProcessCompletionAsync(dbContext, orderId, messageId, eventType, processingStartedAt, () => dbContext.SaveChangesAsync());

    /// <summary>
    /// Applies <c>OrderProcessed</c>. If the order is <see cref="OrderState.Processing"/>
    /// this is a single Processing → Completed transition. If it is still
    /// <see cref="OrderState.Confirmed"/> (the started event has not arrived),
    /// both legs -- Confirmed → Processing → Completed -- are applied in TWO
    /// SaveChanges calls inside ONE explicit database transaction (so the
    /// Processing history row's Seq precedes the Completed row's, review R9),
    /// and the Processing history row is marked
    /// <see cref="OrderStatusHistory.Implied"/> with
    /// <see cref="OrderStatusHistory.At"/> = the later of the Worker's start time
    /// (<paramref name="processingStartedAt"/>) and the confirmation time, per
    /// docs/order-state-machine.md (review R1).
    /// </summary>
    public static Task<ResultProcessingOutcome> ProcessCompletionAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType,
        DateTime? processingStartedAt, Func<Task<int>> saveChangesAsync) =>
        RetryOnStateConflictAsync(dbContext,
            () => ProcessCompletionOnceAsync(dbContext, orderId, messageId, eventType, processingStartedAt, saveChangesAsync));

    private static async Task<ResultProcessingOutcome> ProcessCompletionOnceAsync(
        OrderServiceDbContext dbContext, Guid orderId, Guid messageId, string eventType,
        DateTime? processingStartedAt, Func<Task<int>> saveChangesAsync)
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

        if (order.State == OrderState.PendingStock)
        {
            return ResultProcessingOutcome.NotYetApplicable;
        }

        if (order.State == OrderState.Completed)
        {
            // Same state: a no-op. Record the Inbox row so a redelivery of this
            // exact MessageId short-circuits. No history row is written.
            dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));
            try
            {
                await saveChangesAsync();
            }
            catch (DbUpdateException ex) when (IsUniqueViolation(ex))
            {
                // Concurrent identical delivery already recorded this Inbox row.
            }

            return ResultProcessingOutcome.AlreadyProcessed;
        }

        if (order.State == OrderState.Confirmed)
        {
            // The started event has not arrived: apply both legs -- Confirmed ->
            // Processing -> Completed -- with the middle Processing row implied.
            var from = order.State;
            order.TransitionTo(OrderState.Processing);
            dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
                Guid.NewGuid(), orderId, from, OrderState.Processing, messageId,
                ImpliedProcessingAt(order, processingStartedAt), implied: true));

            // Two SaveChanges in one explicit transaction (review R9). A single
            // SaveChanges could order the two history INSERTs by their random
            // Guid key, so the Processing row's Seq would not be guaranteed to
            // precede the Completed row's. Saving the Processing row first fixes
            // the Seq order; the transaction keeps the change atomic.
            await using var tx = await dbContext.Database.BeginTransactionAsync();
            try
            {
                await saveChangesAsync(); // Processing row -> smaller Seq

                order.TransitionTo(OrderState.Completed);
                dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
                    Guid.NewGuid(), orderId, OrderState.Processing, OrderState.Completed, messageId,
                    order.CompletedAt!.Value, implied: false));
                dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));
                await saveChangesAsync(); // Completed + Inbox rows -> larger Seq

                await tx.CommitAsync();
            }
            catch (DbUpdateException ex) when (IsUniqueViolation(ex))
            {
                await tx.RollbackAsync();
                return ResultProcessingOutcome.AlreadyProcessed;
            }

            return ResultProcessingOutcome.Applied;
        }

        // Processing -> Completed. Rejected (and the unreachable
        // ProcessingFailed) fall through to TransitionTo below and throw
        // InvalidOrderStateTransitionException.
        var fromState = order.State;
        order.TransitionTo(OrderState.Completed);
        dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
            Guid.NewGuid(), orderId, fromState, OrderState.Completed, messageId,
            order.CompletedAt!.Value, implied: false));

        dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, eventType));

        try
        {
            await saveChangesAsync();
        }
        catch (DbUpdateException ex) when (IsUniqueViolation(ex))
        {
            return ResultProcessingOutcome.AlreadyProcessed;
        }

        return ResultProcessingOutcome.Applied;
    }

    // Order.State is a concurrency token (OrderServiceDbContext), so an UPDATE
    // whose order changed state after this call read it matches no row. That
    // is not an error: another consumer moved the order on (for example the
    // completion landed while a start event was deciding). Discard this
    // attempt's tracked changes and decide again from a fresh read, which then
    // sees the newer state and usually answers AlreadyProcessed. The state only
    // moves forward along a short path, so a few attempts are enough; a
    // conflict that keeps repeating is thrown to the consumer's retry ladder.
    private const int MaxStateConflictAttempts = 4;

    private static async Task<ResultProcessingOutcome> RetryOnStateConflictAsync(
        OrderServiceDbContext dbContext, Func<Task<ResultProcessingOutcome>> attempt)
    {
        for (var i = 1; ; i++)
        {
            try
            {
                return await attempt();
            }
            catch (Exception ex) when (IsStateConflict(ex) && i < MaxStateConflictAttempts)
            {
                ConsumerMetrics.StateConflicts.Inc();
                dbContext.ChangeTracker.Clear();
            }
        }
    }

    // AbpDbContext rethrows EF's DbUpdateConcurrencyException as
    // AbpDbConcurrencyException; the test path (SaveChangesOnDbContextAsync)
    // does not, so both are recognised.
    private static bool IsStateConflict(Exception ex) =>
        ex is DbUpdateConcurrencyException || ex is Volo.Abp.Data.AbpDbConcurrencyException;

    // Only a unique-key violation means "a concurrent delivery already recorded
    // this". Any other database error (connection lost, permission, ...) must
    // propagate so the consumer retries and finally dead-letters the message;
    // treating it as a duplicate would ack it and lose the result, leaving the
    // order behind (docs/design-decisions.md section 4).
    private static bool IsUniqueViolation(DbUpdateException ex) =>
        ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation };

    // Happy-path progression for the "same or earlier state" rule. Rejected is
    // off the path: it only matches itself, so StockRejected after Confirmed (or
    // StockReserved after Rejected) stays a genuine conflict. ProcessingFailed is
    // terminal and unreachable, so it is also off the path.
    private static readonly OrderState[] Progression =
        [OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing, OrderState.Completed];

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

    // "Can this event never be applied until a later one arrives?" -- the two
    // Worker events that depend on StockReserved having landed first. Kept as a
    // named rule rather than an inline condition so the caller's requeue
    // decision reads as what it is (an ordering fact), and so a third such event
    // can be added here rather than by weakening the IsAtOrPast no-op rule above,
    // which must keep meaning "someone already applied this".
    private static bool IsAwaitingPrerequisite(OrderState current, OrderState target) =>
        current == OrderState.PendingStock && (target == OrderState.Processing || target == OrderState.Completed);

    // The history "At" for a transition that Order.TransitionTo stamps onto the
    // order (Confirmed/Rejected -> ConfirmedOrRejectedAt, Completed -> CompletedAt)
    // is that stamp. Processing has no order column (docs/order-state-machine.md
    // keeps the existing orders timestamp columns as they are), so its row takes
    // the apply time.
    private static DateTime TransitionTime(Order order, OrderState toState) => toState switch
    {
        OrderState.Confirmed or OrderState.Rejected => order.ConfirmedOrRejectedAt!.Value,
        OrderState.Completed => order.CompletedAt!.Value,
        _ => UtcNowMicroseconds(),
    };

    // The Process Worker consumes StockReserved in parallel with Order Service,
    // so it can begin work (and stamp its start time) before Order Service
    // records Confirmed. The implied Processing row's time is therefore the
    // LATER of the Worker's start time and the confirmation time, so the history
    // time never goes backwards (review R1). A missing start time (an
    // OrderProcessed published by an older Worker, which deserializes without
    // the field) is treated as the apply time, not year 0001 (review R2).
    private static DateTime ImpliedProcessingAt(Order order, DateTime? processingStartedAt)
    {
        var startedAt = processingStartedAt is null || processingStartedAt == default(DateTime)
            ? UtcNowMicroseconds()
            : processingStartedAt.Value;
        return startedAt > order.ConfirmedOrRejectedAt!.Value ? startedAt : order.ConfirmedOrRejectedAt.Value;
    }

    /// <summary>
    /// PostgreSQL stores timestamps at microsecond precision, while
    /// DateTime.UtcNow has 100 ns ticks. Truncating here makes the value written
    /// for an implied Processing row equal the value read back later, matching
    /// <see cref="Order"/>'s own UtcNowMicroseconds convention.
    /// </summary>
    private static DateTime UtcNowMicroseconds()
    {
        var now = DateTime.UtcNow;
        return new DateTime(now.Ticks - now.Ticks % 10, DateTimeKind.Utc);
    }
}
