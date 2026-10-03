using System;
using System.Linq;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using FlashSale.OrderService.Messaging;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Checklist Step 9.4: publishes the same result message (same MessageId)
/// through <see cref="StockResultProcessor"/> twice and asserts the business
/// side effect (the order's state change) happened exactly once. "Publishes
/// twice" here means invoking the processor twice with an identical
/// MessageId, the same way a real redelivered RabbitMQ message would --
/// there's no broker in this test, on purpose: StockResultConsumer's own
/// broker plumbing (ack/nack, deserialization) has no correctness logic of
/// its own, so a broker-level test would mostly be testing RabbitMQ.Client,
/// not this project's idempotency guarantee. See docs comment on
/// StockResultProcessor for why the logic under test lives there.
///
/// Same real-SQLite-engine reasoning as OutboxAtomicityTests: the unique
/// constraint on MessageId is the actual mechanism being proven, and EF
/// Core's InMemory provider doesn't enforce unique constraints at all.
/// </summary>
public class DuplicateMessageIdempotencyTests : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public DuplicateMessageIdempotencyTests()
    {
        _connection = new SqliteConnection("DataSource=:memory:");
        _connection.Open();

        var options = new DbContextOptionsBuilder<OrderServiceDbContext>()
            .UseSqlite(_connection)
            .Options;

        _dbContext = new OrderServiceDbContext(options);
        _dbContext.Database.EnsureCreated();
    }

    public void Dispose()
    {
        _dbContext.Dispose();
        _connection.Dispose();
    }

    private static Order NewPendingOrder() =>
        new(Guid.NewGuid(), "idem-key-" + Guid.NewGuid(), "product-1", 1, "corr-" + Guid.NewGuid());

    [Fact]
    public async Task Redelivered_StockReserved_message_transitions_order_exactly_once()
    {
        var order = NewPendingOrder();
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var messageId = Guid.NewGuid();

        // First delivery: applies the real transition.
        var firstOutcome = await ProcessWithBypassAsync(order.Id, messageId);
        Assert.Equal(ResultProcessingOutcome.Applied, firstOutcome);

        // Second delivery of the SAME message (RabbitMQ's at-least-once
        // guarantee means this is expected, not a bug) -- must be a no-op,
        // not a second transition attempt (which would throw, since
        // Confirmed has no legal self-loop -- see Order.LegalTransitions).
        var secondOutcome = await ProcessWithBypassAsync(order.Id, messageId);
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, secondOutcome);

        await using var freshDbContext = FreshDbContext();
        var persisted = await freshDbContext.Orders.SingleAsync(o => o.Id == order.Id);
        Assert.Equal(OrderState.Confirmed, persisted.State);

        // The actual proof of "exactly once", not just "didn't throw": only
        // one Inbox row exists for this MessageId, and only one
        // ConfirmedOrRejectedAt stamp was ever set (a second real transition
        // would have re-stamped it, which we can't observe directly here, but
        // a duplicate Inbox row would be directly visible and is the
        // mechanism that prevented the second stamp in the first place).
        var inboxRowCount = await freshDbContext.ProcessedMessages.CountAsync(m => m.MessageId == messageId);
        Assert.Equal(1, inboxRowCount);
    }

    [Fact]
    public async Task Two_different_messages_for_the_same_order_do_not_double_process()
    {
        // Distinct from the test above: this proves the Inbox is keyed on
        // MessageId, not on OrderId -- a second, DIFFERENT message for an
        // order already in the target state is also a safe no-op (handled by
        // the "already in target state" branch in StockResultProcessor, not
        // the Inbox-hit branch), and must not throw
        // InvalidOrderStateTransitionException.
        var order = NewPendingOrder();
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var firstOutcome = await ProcessWithBypassAsync(order.Id, Guid.NewGuid());
        Assert.Equal(ResultProcessingOutcome.Applied, firstOutcome);

        var secondOutcome = await ProcessWithBypassAsync(order.Id, Guid.NewGuid());
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, secondOutcome);

        await using var freshDbContext = FreshDbContext();
        Assert.Equal(OrderState.Confirmed, (await freshDbContext.Orders.SingleAsync(o => o.Id == order.Id)).State);
        // Both distinct MessageIds get their own Inbox row -- the Inbox
        // records "this broker message was seen", not "this order is done".
        Assert.Equal(2, await freshDbContext.ProcessedMessages.CountAsync());
    }

    [Fact]
    public async Task OrderProcessed_arriving_before_StockReserved_is_not_applied_and_not_recorded()
    {
        // Week 9 box 2 (docs/design-decisions.md section 2): the Process Worker
        // consumes StockReserved in parallel with this service, so a completion
        // can arrive first. Before the fix this threw
        // InvalidOrderStateTransitionException (PendingStock has no transition
        // to Completed), which the consumer treated as deterministic and sent
        // straight to the DLQ -- the completion was then lost for good and the
        // order stayed PendingStock.
        var order = NewPendingOrder();
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var earlyMessageId = Guid.NewGuid();
        var outcome = await ProcessWithBypassAsync(order.Id, earlyMessageId, OrderState.Completed);

        Assert.Equal(ResultProcessingOutcome.NotYetApplicable, outcome);

        await using var freshDbContext = FreshDbContext();
        Assert.Equal(OrderState.PendingStock, (await freshDbContext.Orders.SingleAsync(o => o.Id == order.Id)).State);
        // Critical, and the reason the retried copy can still work: a message
        // that was not applied must not be recorded as processed, or the
        // requeued copy would be dropped by the Inbox check when it comes back.
        Assert.False(await freshDbContext.ProcessedMessages.AnyAsync(m => m.MessageId == earlyMessageId));
        Assert.Empty(await freshDbContext.ProcessedMessages.ToListAsync());
    }

    [Fact]
    public async Task OrderProcessed_is_applied_once_StockReserved_has_landed()
    {
        // The other half of the same case: the retried completion must be
        // applied normally once the order is Confirmed, exactly once.
        var order = NewPendingOrder();
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var earlyMessageId = Guid.NewGuid();
        Assert.Equal(
            ResultProcessingOutcome.NotYetApplicable,
            await ProcessWithBypassAsync(order.Id, earlyMessageId, OrderState.Completed));

        Assert.Equal(
            ResultProcessingOutcome.Applied,
            await ProcessWithBypassAsync(order.Id, Guid.NewGuid(), OrderState.Confirmed));

        // The retried copy, same MessageId as the early one -- the Inbox has
        // nothing recorded for it, so it applies.
        Assert.Equal(
            ResultProcessingOutcome.Applied,
            await ProcessWithBypassAsync(order.Id, earlyMessageId, OrderState.Completed));

        await using var freshDbContext = FreshDbContext();
        var persisted = await freshDbContext.Orders.SingleAsync(o => o.Id == order.Id);
        Assert.Equal(OrderState.Completed, persisted.State);
        Assert.NotNull(persisted.CompletedAt);
        Assert.Equal(1, await freshDbContext.ProcessedMessages.CountAsync(m => m.MessageId == earlyMessageId));

        // And a further redelivery of that same message stays a no-op.
        Assert.Equal(
            ResultProcessingOutcome.AlreadyProcessed,
            await ProcessWithBypassAsync(order.Id, earlyMessageId, OrderState.Completed));
    }

    [Fact]
    public async Task Conflicting_result_for_an_already_Rejected_order_throws_and_is_not_recorded()
    {
        var order = NewPendingOrder();
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        await ProcessWithBypassAsync(order.Id, Guid.NewGuid(), OrderState.Rejected);

        // A genuine conflict, not a redelivery: some other message now claims
        // this order should be Confirmed, despite it already being Rejected.
        // StockResultConsumer nacks this without requeue (checklist Step
        // 8.2); the processor's job is only to let the real exception surface
        // rather than swallow it as if it were an idempotent no-op.
        var conflictingMessageId = Guid.NewGuid();
        await Assert.ThrowsAsync<InvalidOrderStateTransitionException>(
            () => ProcessWithBypassAsync(order.Id, conflictingMessageId, OrderState.Confirmed));

        await using var freshDbContext = FreshDbContext();
        Assert.Equal(OrderState.Rejected, (await freshDbContext.Orders.SingleAsync(o => o.Id == order.Id)).State);
        // The failed attempt must not leave behind an Inbox row -- it never
        // reached a successful SaveChangesAsync, so nothing should be
        // recorded as "processed" for a transition that never actually applied.
        Assert.False(await freshDbContext.ProcessedMessages.AnyAsync(m => m.MessageId == conflictingMessageId));
    }

    // Uses StockResultProcessor's save-injectable overload with the
    // SaveChangesOnDbContextAsync bypass (see OutboxAtomicityTests' own
    // comment on why): the real SaveChangesAsync needs ABP's full DI
    // container, which a directly-constructed DbContext in a test doesn't
    // have. Production (StockResultConsumer) calls the parameterless
    // overload instead, which always uses the real one.
    private Task<ResultProcessingOutcome> ProcessWithBypassAsync(
        Guid orderId, Guid messageId, OrderState targetState = OrderState.Confirmed) =>
        StockResultProcessor.ProcessAsync(
            _dbContext, orderId, messageId, "StockReserved", targetState,
            () => _dbContext.SaveChangesOnDbContextAsync(true));

    private OrderServiceDbContext FreshDbContext() =>
        new(new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);
}
