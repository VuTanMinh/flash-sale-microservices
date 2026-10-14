using System;
using System.Collections.Generic;
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
/// Week 5 roadmap box "legal/duplicate/invalid state behaviour" (test case
/// TP-A06, docs/order-api.md "State behaviour"), updated for the six-state
/// model (Week 11 box 2). Covers the full transition matrix of the current
/// code, and how StockResultProcessor treats duplicate, stale and conflicting
/// events -- both the single-transition entry point (StockReserved/StockRejected/
/// OrderProcessingStarted) and the completion entry point (OrderProcessed).
/// Real SQLite engine for the same reason as DuplicateMessageIdempotencyTests:
/// the Inbox's unique MessageId is part of what is being tested.
/// </summary>
public class OrderStateBehaviourTests : IDisposable
{
    private static readonly HashSet<(OrderState From, OrderState To)> Legal =
    [
        (OrderState.PendingStock, OrderState.Confirmed),
        (OrderState.PendingStock, OrderState.Rejected),
        (OrderState.Confirmed, OrderState.Processing),
        (OrderState.Processing, OrderState.Completed),
    ];

    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public OrderStateBehaviourTests()
    {
        _connection = new SqliteConnection("DataSource=:memory:");
        _connection.Open();
        _dbContext = new OrderServiceDbContext(new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);
        _dbContext.Database.EnsureCreated();
    }

    public void Dispose()
    {
        _dbContext.Dispose();
        _connection.Dispose();
    }

    public static IEnumerable<object[]> AllPairs() =>
        from source in Enum.GetValues<OrderState>()
        where source != OrderState.ProcessingFailed // unreachable: no inbound transition, so it cannot be a current state
        from target in Enum.GetValues<OrderState>()
        select new object[] { source, target };

    [Theory]
    [MemberData(nameof(AllPairs))]
    public void Every_transition_pair_is_either_legal_or_throws(OrderState from, OrderState to)
    {
        var order = OrderIn(from);

        if (Legal.Contains((from, to)))
        {
            order.TransitionTo(to);
            Assert.Equal(to, order.State);
        }
        else
        {
            var ex = Assert.Throws<InvalidOrderStateTransitionException>(() => order.TransitionTo(to));
            Assert.Equal(from, order.State); // a refused transition changes nothing
            Assert.Contains($"'{from}'", ex.Message);
        }
    }

    [Fact]
    public async Task Duplicate_result_with_the_same_MessageId_is_a_no_op()
    {
        var order = await SavedOrderInAsync(OrderState.PendingStock);
        var messageId = Guid.NewGuid();

        Assert.Equal(ResultProcessingOutcome.Applied, await ProcessAsync(order.Id, messageId, "StockReserved", OrderState.Confirmed));
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, await ProcessAsync(order.Id, messageId, "StockReserved", OrderState.Confirmed));

        await using var fresh = Fresh();
        Assert.Equal(OrderState.Confirmed, (await fresh.Orders.SingleAsync()).State);
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
        // The second delivery applied no transition, so exactly one Confirmed
        // history row exists. The fixture writes no creation row (only the API
        // does, OrdersController.cs), so the count is 1, not 2.
        Assert.Equal(1, await fresh.OrderStatusHistory.CountAsync());
    }

    [Fact]
    public async Task Duplicate_completion_with_the_same_MessageId_is_a_no_op()
    {
        var order = await SavedOrderInAsync(OrderState.Processing);
        var messageId = order.Id;

        Assert.Equal(ResultProcessingOutcome.Applied, await ProcessCompletionAsync(order.Id, messageId, "OrderProcessed", DateTime.UtcNow));
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, await ProcessCompletionAsync(order.Id, messageId, "OrderProcessed", DateTime.UtcNow));

        await using var fresh = Fresh();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync()).State);
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
    }

    [Theory]
    [InlineData(OrderState.Confirmed, "StockReserved", OrderState.Confirmed)]   // duplicate, new MessageId
    [InlineData(OrderState.Rejected, "StockRejected", OrderState.Rejected)]     // duplicate, new MessageId
    [InlineData(OrderState.Processing, "StockReserved", OrderState.Confirmed)]  // stale: already moved past Confirmed
    [InlineData(OrderState.Completed, "StockReserved", OrderState.Confirmed)]   // stale: already moved past Confirmed
    [InlineData(OrderState.Processing, "OrderProcessingStarted", OrderState.Processing)] // duplicate start
    [InlineData(OrderState.Completed, "OrderProcessingStarted", OrderState.Processing)]  // stale start after Completed
    public async Task Duplicate_or_stale_event_with_a_new_MessageId_is_acknowledged_without_a_transition(
        OrderState current, string eventType, OrderState target)
    {
        var order = await SavedOrderInAsync(current);
        var messageId = Guid.NewGuid();

        var outcome = await ProcessAsync(order.Id, messageId, eventType, target);

        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, outcome);
        await using var fresh = Fresh();
        Assert.Equal(current, (await fresh.Orders.SingleAsync()).State);
        // Recorded, so a redelivery of this exact message short-circuits.
        Assert.True(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    [Fact]
    public async Task Stale_completion_with_a_new_MessageId_after_Completed_is_a_no_op()
    {
        var order = await SavedOrderInAsync(OrderState.Completed);
        var messageId = Guid.NewGuid();

        var outcome = await ProcessCompletionAsync(order.Id, messageId, "OrderProcessed", DateTime.UtcNow);

        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, outcome);
        await using var fresh = Fresh();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync()).State);
        Assert.True(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    [Fact]
    public async Task Start_event_while_PendingStock_is_not_applied_and_not_recorded()
    {
        var order = await SavedOrderInAsync(OrderState.PendingStock);
        var messageId = Guid.NewGuid();

        var outcome = await ProcessAsync(order.Id, messageId, "OrderProcessingStarted", OrderState.Processing);

        Assert.Equal(ResultProcessingOutcome.NotYetApplicable, outcome);
        await using var fresh = Fresh();
        Assert.Equal(OrderState.PendingStock, (await fresh.Orders.SingleAsync()).State);
        Assert.False(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    [Theory]
    [InlineData(OrderState.Confirmed, "StockRejected", OrderState.Rejected)]
    [InlineData(OrderState.Completed, "StockRejected", OrderState.Rejected)]
    [InlineData(OrderState.Rejected, "StockReserved", OrderState.Confirmed)]
    [InlineData(OrderState.Rejected, "OrderProcessingStarted", OrderState.Processing)]
    public async Task Conflicting_event_throws_changes_nothing_and_is_not_recorded(
        OrderState current, string eventType, OrderState target)
    {
        var order = await SavedOrderInAsync(current);
        var messageId = Guid.NewGuid();

        await Assert.ThrowsAsync<InvalidOrderStateTransitionException>(() => ProcessAsync(order.Id, messageId, eventType, target));

        await using var fresh = Fresh();
        Assert.Equal(current, (await fresh.Orders.SingleAsync()).State);
        Assert.False(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    [Fact]
    public async Task Completion_for_a_Rejected_order_throws_and_is_not_recorded()
    {
        var order = await SavedOrderInAsync(OrderState.Rejected);
        var messageId = Guid.NewGuid();

        await Assert.ThrowsAsync<InvalidOrderStateTransitionException>(
            () => ProcessCompletionAsync(order.Id, messageId, "OrderProcessed", DateTime.UtcNow));

        await using var fresh = Fresh();
        Assert.Equal(OrderState.Rejected, (await fresh.Orders.SingleAsync()).State);
        Assert.False(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    [Fact]
    public async Task Result_for_an_unknown_order_is_reported_and_not_recorded()
    {
        var messageId = Guid.NewGuid();
        Assert.Equal(ResultProcessingOutcome.OrderNotFound, await ProcessAsync(Guid.NewGuid(), messageId, "StockReserved", OrderState.Confirmed));
        await using var fresh = Fresh();
        Assert.False(await fresh.ProcessedMessages.AnyAsync(m => m.MessageId == messageId));
    }

    private static Order OrderIn(OrderState state)
    {
        var order = new Order(Guid.NewGuid(), "key-" + Guid.NewGuid(), "product-1", 1, "corr");
        switch (state)
        {
            case OrderState.Confirmed: order.TransitionTo(OrderState.Confirmed); break;
            case OrderState.Rejected: order.TransitionTo(OrderState.Rejected); break;
            case OrderState.Processing: order.TransitionTo(OrderState.Confirmed); order.TransitionTo(OrderState.Processing); break;
            case OrderState.Completed: order.TransitionTo(OrderState.Confirmed); order.TransitionTo(OrderState.Processing); order.TransitionTo(OrderState.Completed); break;
        }
        return order;
    }

    private async Task<Order> SavedOrderInAsync(OrderState state)
    {
        var order = OrderIn(state);
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);
        return order;
    }

    private Task<ResultProcessingOutcome> ProcessAsync(Guid orderId, Guid messageId, string eventType, OrderState target) =>
        StockResultProcessor.ProcessAsync(_dbContext, orderId, messageId, eventType, target,
            () => _dbContext.SaveChangesOnDbContextAsync(true));

    private Task<ResultProcessingOutcome> ProcessCompletionAsync(Guid orderId, Guid messageId, string eventType, DateTime? startedAt) =>
        StockResultProcessor.ProcessCompletionAsync(_dbContext, orderId, messageId, eventType, startedAt,
            () => _dbContext.SaveChangesOnDbContextAsync(true));

    private OrderServiceDbContext Fresh() =>
        new(new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);
}
