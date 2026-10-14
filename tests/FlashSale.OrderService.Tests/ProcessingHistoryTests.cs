using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using FlashSale.OrderService.Messaging;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Week 11 box 2 (TP-P02): the six-state model's Processing history and the
/// success-only interpretation of ProcessingFailed.
///
/// 1. Every 5-event sequence over {StockReserved, OrderProcessingStarted,
///    OrderProcessed} that contains all three -- 150 of them, with duplicates
///    and reordering allowed -- ends Completed with exactly the four-row
///    history PendingStock -> Confirmed -> Processing -> Completed, one row per
///    transition, no duplicates, and never ProcessingFailed.
/// 2. A completion that arrives while the order is still Confirmed (the start
///    event has not landed) writes an implied Processing row whose At is the
///    later of the Worker's start time and the confirmation time (clamped).
/// 3. No input ever reaches ProcessingFailed (success-only Worker).
/// </summary>
public class ProcessingHistoryTests : IDisposable
{
    private static readonly OrderState[] EventKinds =
        [OrderState.Confirmed, OrderState.Processing, OrderState.Completed];

    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public ProcessingHistoryTests()
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

    [Fact]
    public void There_are_exactly_150_sequences_that_contain_all_three_events()
    {
        var sequences = SequencesContainingAllThree();
        Assert.Equal(150, sequences.Count);
    }

    [Fact]
    public async Task Every_sequence_ends_Completed_with_the_four_row_history_and_never_ProcessingFailed()
    {
        var sequences = SequencesContainingAllThree();
        Assert.Equal(150, sequences.Count);

        foreach (var events in sequences)
        {
            var order = await CreateOrderWithHistoryAsync();
            await ReplayAsync(order, events);

            await using var fresh = Fresh();
            var persisted = await fresh.Orders.SingleAsync(o => o.Id == order.Id);
            Assert.Equal(OrderState.Completed, persisted.State);

            var history = (await fresh.OrderStatusHistory.Where(h => h.OrderId == order.Id).ToListAsync())
                .OrderBy(h => FromRank(h.FromState))
                .ToList();

            // Exactly four rows, one per transition, no duplicates, in the
            // progression order (null -> PendingStock -> Confirmed ->
            // Processing -> Completed).
            Assert.Equal(4, history.Count);
            Assert.Equal(
                new OrderState?[] { null, OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing },
                history.Select(h => h.FromState).ToArray());
            Assert.Equal(
                new[] { OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing, OrderState.Completed },
                history.Select(h => h.ToState).ToArray());

            // ProcessingFailed is declared but unreachable: it never appears as
            // either end of any history row.
            Assert.DoesNotContain(history, h => h.FromState == OrderState.ProcessingFailed || h.ToState == OrderState.ProcessingFailed);
        }
    }

    [Fact]
    public async Task Implied_Processing_row_clamps_to_the_confirmation_time_when_start_is_earlier()
    {
        var order = await CreateOrderWithHistoryAsync();

        // Confirmed via StockReserved, but no start event.
        Assert.Equal(
            ResultProcessingOutcome.Applied,
            await StockResultProcessor.ProcessAsync(_dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed, Save));
        var confirmedAt = order.ConfirmedOrRejectedAt!.Value;

        // The Worker consumes StockReserved in parallel and can start before
        // Order Service records Confirmed, so a start time earlier than the
        // confirmation is the normal, common race (review R1): the implied row
        // must be clamped to the confirmation time, not predate it.
        var startedAt = confirmedAt.AddMinutes(-5);

        var outcome = await StockResultProcessor.ProcessCompletionAsync(
            _dbContext, order.Id, order.Id, "OrderProcessed", startedAt, Save);
        Assert.Equal(ResultProcessingOutcome.Applied, outcome);

        await using var fresh = Fresh();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);

        var implied = await fresh.OrderStatusHistory.SingleAsync(h =>
            h.OrderId == order.Id && h.ToState == OrderState.Processing);
        Assert.True(implied.Implied);
        Assert.Equal(OrderState.Confirmed, implied.FromState);
        Assert.Equal(confirmedAt, implied.At);
        Assert.Equal(order.Id, implied.MessageId);
    }

    [Fact]
    public async Task Implied_Processing_row_keeps_the_start_time_when_it_is_later()
    {
        var order = await CreateOrderWithHistoryAsync();
        Assert.Equal(
            ResultProcessingOutcome.Applied,
            await StockResultProcessor.ProcessAsync(_dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed, Save));
        var confirmedAt = order.ConfirmedOrRejectedAt!.Value;

        var startedAt = confirmedAt.AddMinutes(5); // later than the confirmation

        await StockResultProcessor.ProcessCompletionAsync(
            _dbContext, order.Id, order.Id, "OrderProcessed", startedAt, Save);

        await using var fresh = Fresh();
        var implied = await fresh.OrderStatusHistory.SingleAsync(h =>
            h.OrderId == order.Id && h.ToState == OrderState.Processing);
        Assert.True(implied.Implied);
        Assert.Equal(startedAt, implied.At);
    }

    [Fact]
    public async Task Completion_without_ProcessingStartedAt_stamps_the_implied_row_with_the_apply_time()
    {
        var order = await CreateOrderWithHistoryAsync();
        Assert.Equal(
            ResultProcessingOutcome.Applied,
            await StockResultProcessor.ProcessAsync(_dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed, Save));
        var confirmedAt = order.ConfirmedOrRejectedAt!.Value;

        // null models an OrderProcessed published by an older Worker that omits
        // ProcessingStartedAt entirely (review R2): it must not become year
        // 0001, but fall back to the apply time (clamped to the confirmation).
        await StockResultProcessor.ProcessCompletionAsync(
            _dbContext, order.Id, order.Id, "OrderProcessed", null, Save);

        await using var fresh = Fresh();
        var implied = await fresh.OrderStatusHistory.SingleAsync(h =>
            h.OrderId == order.Id && h.ToState == OrderState.Processing);
        Assert.True(implied.Implied);
        Assert.NotEqual(default(DateTime), implied.At);
        Assert.True(implied.At >= confirmedAt);
    }

    [Fact]
    public async Task History_read_ordered_by_Seq_matches_the_transition_order()
    {
        var order = await CreateOrderWithHistoryAsync(); // creation row first
        await StockResultProcessor.ProcessAsync(_dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed, Save);
        await StockResultProcessor.ProcessAsync(
            _dbContext, order.Id, OrderProcessingStartedEto.DeriveMessageId(order.Id), "OrderProcessingStarted", OrderState.Processing, Save);
        await StockResultProcessor.ProcessCompletionAsync(_dbContext, order.Id, order.Id, "OrderProcessed", DateTime.UtcNow, Save);

        await using var fresh = Fresh();
        var ordered = await fresh.OrderStatusHistory
            .Where(h => h.OrderId == order.Id)
            .OrderBy(h => h.Seq)
            .Select(h => h.ToState)
            .ToListAsync();

        Assert.Equal(
            new[] { OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing, OrderState.Completed },
            ordered);
    }

    [Fact]
    public async Task A_failed_save_leaves_no_state_change_and_no_history_row()
    {
        // The history row and the state write are one SaveChanges call, so a
        // database failure between the transition and the commit must leave
        // neither behind -- the state change and its history row are atomic.
        var order = await CreateOrderWithHistoryAsync();
        var messageId = Guid.NewGuid();

        // The injected save throws before anything commits, simulating a
        // database failure mid-request.
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            StockResultProcessor.ProcessAsync(
                _dbContext, order.Id, messageId, "StockReserved", OrderState.Confirmed,
                () => throw new InvalidOperationException("db down")));

        await using var fresh = Fresh();
        Assert.Equal(OrderState.PendingStock, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);
        Assert.Equal(1, await fresh.OrderStatusHistory.CountAsync(h => h.OrderId == order.Id));
    }

    private static List<OrderState[]> SequencesContainingAllThree()
    {
        var all = new List<OrderState[]>();
        foreach (var a in EventKinds)
        foreach (var b in EventKinds)
        foreach (var c in EventKinds)
        foreach (var d in EventKinds)
        foreach (var e in EventKinds)
        {
            var sequence = new[] { a, b, c, d, e };
            if (sequence.Distinct().Count() == EventKinds.Length)
            {
                all.Add(sequence);
            }
        }
        return all;
    }

    private async Task<Order> CreateOrderWithHistoryAsync()
    {
        // Mirrors OrdersController.CreateOrderAsync: the order and its creation
        // history row commit in one SaveChanges.
        var order = new Order(Guid.NewGuid(), "key-" + Guid.NewGuid(), "product-1", 1, "corr-" + Guid.NewGuid());
        _dbContext.Orders.Add(order);
        _dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
            Guid.NewGuid(), order.Id, null, OrderState.PendingStock, null, order.RequestAcceptedAt, false));
        await Save();
        return order;
    }

    private async Task ReplayAsync(Order order, OrderState[] events)
    {
        var reservedMessageId = Guid.NewGuid();
        var startedMessageId = OrderProcessingStartedEto.DeriveMessageId(order.Id);
        var startedAt = DateTime.UtcNow;

        var queue = new Queue<(OrderState Target, string EventType, Guid MessageId, DateTime? StartedAt)>();
        foreach (var e in events)
        {
            queue.Enqueue(e switch
            {
                OrderState.Confirmed => (OrderState.Confirmed, "StockReserved", reservedMessageId, (DateTime?)null),
                OrderState.Processing => (OrderState.Processing, "OrderProcessingStarted", startedMessageId, startedAt),
                OrderState.Completed => (OrderState.Completed, "OrderProcessed", order.Id, startedAt),
                _ => throw new ArgumentOutOfRangeException(nameof(events)),
            });
        }

        // "While PendingStock -> retry later" is the consumer's delayed
        // requeue, modelled here as re-enqueueing at the back of the queue:
        // the event is not dropped and not applied until StockReserved lands.
        var guard = 0;
        while (queue.Count > 0 && guard++ < 1000)
        {
            var e = queue.Dequeue();
            var outcome = e.Target == OrderState.Completed
                ? await StockResultProcessor.ProcessCompletionAsync(_dbContext, order.Id, e.MessageId, e.EventType, e.StartedAt, Save)
                : await StockResultProcessor.ProcessAsync(_dbContext, order.Id, e.MessageId, e.EventType, e.Target, Save);

            if (outcome == ResultProcessingOutcome.NotYetApplicable)
            {
                queue.Enqueue(e);
            }
        }

        Assert.Empty(queue);
    }

    private static int FromRank(OrderState? from) => from switch
    {
        null => 0,
        OrderState.PendingStock => 1,
        OrderState.Confirmed => 2,
        OrderState.Processing => 3,
        _ => int.MaxValue,
    };

    private Task<int> Save() => _dbContext.SaveChangesOnDbContextAsync(true);

    private OrderServiceDbContext Fresh() =>
        new(new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);
}
