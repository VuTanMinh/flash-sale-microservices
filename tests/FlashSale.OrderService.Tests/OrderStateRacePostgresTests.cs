using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using FlashSale.OrderService.Messaging;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Midterm review finding A, PostgreSQL integration check for concurrent
/// order-state updates.
///
/// OrderStateBehaviourTests proves Order.State works as an EF Core concurrency
/// token on in-memory SQLite, with the conflicting write done inside the save
/// hook on the SAME connection. This class re-proves the same guarantee on
/// real PostgreSQL, deterministically, with two separate
/// <see cref="OrderServiceDbContext"/> instances (separate connections) and
/// SemaphoreSlim/TaskCompletionSource barriers that force the interleaving
/// instead of relying on Task.Delay timing.
///
/// Isolation: each class run creates its own database
/// <c>flashsale_race_&lt;hex&gt;</c> with CREATE DATABASE, builds the schema
/// with <see cref="OrderServiceDbContext"/> + UseNpgsql +
/// EnsureCreated(), and drops that database in Dispose. It never touches the
/// database named in the connection string beyond CREATE/DROP of its own
/// database. When the <c>FLASHSALE_TEST_PG</c> environment variable is not set
/// every test is SKIPPED (via <see cref="PostgresFactAttribute"/>), never
/// silently passed.
/// </summary>
public class OrderStateRacePostgresTests : IDisposable
{
    private readonly string _adminConnectionString;
    private readonly string _databaseName;
    private readonly string _connectionString;
    private readonly OrderServiceDbContext _dbContext;

    public OrderStateRacePostgresTests()
    {
        // [PostgresFact] skips every test when this is missing, so the
        // constructor never runs in that case. The throw is a guard against a
        // mismatch (it is a clear failure, never a silent pass).
        _adminConnectionString = Environment.GetEnvironmentVariable("FLASHSALE_TEST_PG")
            ?? throw new InvalidOperationException(
                "FLASHSALE_TEST_PG is not set; [PostgresFact] should have skipped this test. " +
                "Set it to an Npgsql connection string for an admin account.");

        _databaseName = "flashsale_race_" + Convert.ToHexString(RandomNumberGenerator.GetBytes(6)).ToLowerInvariant();

        using (var admin = new NpgsqlConnection(_adminConnectionString))
        {
            admin.Open();
            using var create = new NpgsqlCommand($"CREATE DATABASE \"{_databaseName}\"", admin);
            create.ExecuteNonQuery();
        }

        _connectionString = new NpgsqlConnectionStringBuilder(_adminConnectionString)
        {
            Database = _databaseName,
        }.ConnectionString;

        _dbContext = NewContext();
        _dbContext.Database.EnsureCreated();
    }

    public void Dispose()
    {
        try
        {
            _dbContext.Dispose();
        }
        catch
        {
            // Best-effort: a failed dispose must not mask the test result.
        }

        try
        {
            using var admin = new NpgsqlConnection(_adminConnectionString);
            admin.Open();
            // WITH (FORCE) terminates pooled connections still pointing at the
            // throwaway database so the DROP does not block (PostgreSQL 13+).
            using var drop = new NpgsqlCommand($"DROP DATABASE IF EXISTS \"{_databaseName}\" WITH (FORCE)", admin);
            drop.ExecuteNonQuery();
        }
        catch
        {
            // A failed DROP must not mask the test result; the throwaway name
            // keeps any leftover database harmless.
        }
    }

    /// <summary>
    /// Case (a): the start handler reads Confirmed and waits at the barrier; the
    /// completion handler commits Completed; the start is then released. Its
    /// UPDATE (WHERE state = Confirmed) now matches no row, so it loses the
    /// concurrency race, re-reads Completed and acknowledges itself as stale.
    /// </summary>
    [PostgresFact]
    public async Task Start_after_completion_never_moves_the_order_back()
    {
        var order = await SeedOrderAsync(OrderState.Confirmed);
        var startMessageId = Guid.NewGuid();

        var startEnteredSave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var completionCommitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var startContext = NewContext();
        await using var completionContext = NewContext();

        var startTask = StockResultProcessor.ProcessAsync(
            startContext, order.Id, startMessageId, "OrderProcessingStarted", OrderState.Processing,
            async () =>
            {
                startEnteredSave.TrySetResult();
                await completionCommitted.Task;
                return await startContext.SaveChangesOnDbContextAsync(true);
            });

        // Wait until the start handler has READ the order (it is inside its save
        // hook: entity loaded Confirmed, change pending) before completion commits.
        await startEnteredSave.Task;

        var completionOutcome = await StockResultProcessor.ProcessCompletionAsync(
            completionContext, order.Id, order.Id, "OrderProcessed", DateTime.UtcNow,
            () => completionContext.SaveChangesOnDbContextAsync(true));

        completionCommitted.TrySetResult();
        var startOutcome = await startTask;

        Assert.Equal(ResultProcessingOutcome.Applied, completionOutcome);
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, startOutcome);

        await using var fresh = NewContext();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);
        // The stale start applied no transition, so no history row leaves Completed.
        Assert.False(await fresh.OrderStatusHistory.AnyAsync(h => h.FromState == OrderState.Completed));
        // The stale start is still recorded so a redelivery short-circuits.
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == startMessageId));
    }

    /// <summary>
    /// Case (b): completion reads Confirmed and waits at the barrier; start
    /// commits Processing; completion is released. Its first save (implied
    /// Confirmed -> Processing) loses the race and rolls back, so it re-reads
    /// Processing and applies only the remaining Processing -> Completed leg.
    /// </summary>
    [PostgresFact]
    public async Task Completion_after_start_applies_only_the_remaining_leg()
    {
        var order = await SeedOrderAsync(OrderState.Confirmed);
        var startMessageId = Guid.NewGuid();

        var completionEnteredSave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var startCommitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var completionContext = NewContext();
        await using var startContext = NewContext();

        var completionTask = StockResultProcessor.ProcessCompletionAsync(
            completionContext, order.Id, order.Id, "OrderProcessed", DateTime.UtcNow,
            async () =>
            {
                completionEnteredSave.TrySetResult();
                await startCommitted.Task;
                return await completionContext.SaveChangesOnDbContextAsync(true);
            });

        // Completion has READ Confirmed and is inside its first save hook (change
        // pending) when the start commits Processing.
        await completionEnteredSave.Task;

        var startOutcome = await StockResultProcessor.ProcessAsync(
            startContext, order.Id, startMessageId, "OrderProcessingStarted", OrderState.Processing,
            () => startContext.SaveChangesOnDbContextAsync(true));

        startCommitted.TrySetResult();
        var completionOutcome = await completionTask;

        Assert.Equal(ResultProcessingOutcome.Applied, startOutcome);
        Assert.Equal(ResultProcessingOutcome.Applied, completionOutcome);

        await using var fresh = NewContext();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);

        var history = await fresh.OrderStatusHistory
            .Where(h => h.OrderId == order.Id)
            .OrderBy(h => h.Seq)
            .ToListAsync();

        // Exactly the two real transitions. The completion's implied-Processing
        // attempt lost the concurrency race and rolled back, so there is no
        // implied row: the legs are Confirmed -> Processing (start) and
        // Processing -> Completed (completion re-decision).
        Assert.Equal(2, history.Count);
        Assert.Equal(
            new OrderState?[] { OrderState.Confirmed, OrderState.Processing },
            history.Select(h => h.FromState).ToArray());
        Assert.Equal(
            new[] { OrderState.Processing, OrderState.Completed },
            history.Select(h => h.ToState).ToArray());
        Assert.All(history, h => Assert.False(h.Implied));

        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == startMessageId));
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == order.Id));
    }

    /// <summary>
    /// Case (c): two start handlers with the SAME MessageId both read Confirmed
    /// and wait; both are released. Exactly one wins (Applied) and the other
    /// acknowledges as AlreadyProcessed, with no unhandled exception.
    /// </summary>
    [PostgresFact]
    public async Task Concurrent_duplicate_starts_apply_exactly_once()
    {
        var order = await SeedOrderAsync(OrderState.Confirmed);
        var messageId = Guid.NewGuid();

        var firstEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var firstContext = NewContext();
        await using var secondContext = NewContext();

        var firstTask = StockResultProcessor.ProcessAsync(
            firstContext, order.Id, messageId, "OrderProcessingStarted", OrderState.Processing,
            async () =>
            {
                firstEntered.TrySetResult();
                await release.Task;
                return await firstContext.SaveChangesOnDbContextAsync(true);
            });

        var secondTask = StockResultProcessor.ProcessAsync(
            secondContext, order.Id, messageId, "OrderProcessingStarted", OrderState.Processing,
            async () =>
            {
                secondEntered.TrySetResult();
                await release.Task;
                return await secondContext.SaveChangesOnDbContextAsync(true);
            });

        // Both handlers have READ Confirmed (both inside their save hooks) before
        // either is released, so the conflict is forced, not a timing accident.
        await Task.WhenAll(firstEntered.Task, secondEntered.Task);
        release.TrySetResult();

        var outcomes = await Task.WhenAll(firstTask, secondTask);

        Assert.Equal(1, outcomes.Count(o => o == ResultProcessingOutcome.Applied));
        Assert.Equal(1, outcomes.Count(o => o == ResultProcessingOutcome.AlreadyProcessed));

        await using var fresh = NewContext();
        Assert.Equal(OrderState.Processing, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);
        Assert.Equal(1, await fresh.OrderStatusHistory.CountAsync(h => h.OrderId == order.Id));
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
    }

    /// <summary>
    /// Case (d): an order in PendingStock; a StockReserved and a StockRejected
    /// handler (different MessageIds) both read PendingStock and wait. The
    /// reserved one is released first and commits Confirmed; the rejected one is
    /// then released, loses the race, re-reads Confirmed and throws the
    /// documented conflicting-event exception, recording nothing.
    /// </summary>
    [PostgresFact]
    public async Task Conflicting_stock_outcomes_throw_and_record_nothing()
    {
        var order = await SeedOrderAsync(OrderState.PendingStock);
        var reservedMessageId = Guid.NewGuid();
        var rejectedMessageId = Guid.NewGuid();

        var reservedEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var rejectedEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reservedGo = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var rejectedGo = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var reservedContext = NewContext();
        await using var rejectedContext = NewContext();

        var reservedTask = StockResultProcessor.ProcessAsync(
            reservedContext, order.Id, reservedMessageId, "StockReserved", OrderState.Confirmed,
            async () =>
            {
                reservedEntered.TrySetResult();
                await reservedGo.Task;
                return await reservedContext.SaveChangesOnDbContextAsync(true);
            });

        var rejectedTask = StockResultProcessor.ProcessAsync(
            rejectedContext, order.Id, rejectedMessageId, "StockRejected", OrderState.Rejected,
            async () =>
            {
                rejectedEntered.TrySetResult();
                await rejectedGo.Task;
                return await rejectedContext.SaveChangesOnDbContextAsync(true);
            });

        await Task.WhenAll(reservedEntered.Task, rejectedEntered.Task);

        // Release the reserved handler first so it wins the race to Confirmed.
        reservedGo.TrySetResult();
        Assert.Equal(ResultProcessingOutcome.Applied, await reservedTask);

        // The rejected handler read PendingStock before the reserved commit, so
        // its save loses the race and its re-decision (Confirmed -> Rejected)
        // is an illegal transition.
        rejectedGo.TrySetResult();
        await Assert.ThrowsAsync<InvalidOrderStateTransitionException>(async () => await rejectedTask);

        await using var fresh = NewContext();
        Assert.Equal(OrderState.Confirmed, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);
        Assert.Equal(1, await fresh.OrderStatusHistory.CountAsync(h => h.OrderId == order.Id));
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == reservedMessageId));
        Assert.Equal(0, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == rejectedMessageId));
    }

    /// <summary>
    /// Case (e): after an order is driven to Completed, regressing events are
    /// acknowledged as stale no-ops, and the invariant holds across the whole
    /// database: no history row leaves Completed, and every order's State equals
    /// the last ToState in its own history (ordered by Seq).
    /// </summary>
    [PostgresFact]
    public async Task Completed_never_regresses_and_history_agrees_with_state()
    {
        var order = await SeedOrderAsync(OrderState.PendingStock);

        Assert.Equal(ResultProcessingOutcome.Applied, await StockResultProcessor.ProcessAsync(
            _dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed,
            () => _dbContext.SaveChangesOnDbContextAsync(true)));
        Assert.Equal(ResultProcessingOutcome.Applied, await StockResultProcessor.ProcessAsync(
            _dbContext, order.Id, Guid.NewGuid(), "OrderProcessingStarted", OrderState.Processing,
            () => _dbContext.SaveChangesOnDbContextAsync(true)));
        Assert.Equal(ResultProcessingOutcome.Applied, await StockResultProcessor.ProcessCompletionAsync(
            _dbContext, order.Id, order.Id, "OrderProcessed", DateTime.UtcNow,
            () => _dbContext.SaveChangesOnDbContextAsync(true)));

        // Regressing events after Completed are acknowledged as stale no-ops.
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, await StockResultProcessor.ProcessAsync(
            _dbContext, order.Id, Guid.NewGuid(), "OrderProcessingStarted", OrderState.Processing,
            () => _dbContext.SaveChangesOnDbContextAsync(true)));
        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, await StockResultProcessor.ProcessAsync(
            _dbContext, order.Id, Guid.NewGuid(), "StockReserved", OrderState.Confirmed,
            () => _dbContext.SaveChangesOnDbContextAsync(true)));

        await using var fresh = NewContext();

        Assert.False(await fresh.OrderStatusHistory.AnyAsync(h => h.FromState == OrderState.Completed));

        var orderIds = await fresh.Orders.Select(o => o.Id).ToListAsync();
        foreach (var orderId in orderIds)
        {
            var state = await fresh.Orders.Where(o => o.Id == orderId).Select(o => o.State).SingleAsync();
            var lastToState = await fresh.OrderStatusHistory
                .Where(h => h.OrderId == orderId)
                .OrderByDescending(h => h.Seq)
                .Select(h => (OrderState?)h.ToState)
                .FirstOrDefaultAsync();

            Assert.NotNull(lastToState);
            Assert.Equal(state, lastToState!.Value);
        }
    }

    /// <summary>
    /// Production saves through AbpDbContext.SaveChangesAsync, which rethrows
    /// EF's DbUpdateConcurrencyException as AbpDbConcurrencyException. The save
    /// hook here does the same rewrap (matching OrderStateBehaviourTests) so the
    /// production exception type is proven to trigger the re-decision too.
    /// </summary>
    [PostgresFact]
    public async Task Conflict_is_redecided_when_rewrapped_as_AbpDbConcurrencyException()
    {
        var order = await SeedOrderAsync(OrderState.Confirmed);
        var startMessageId = Guid.NewGuid();

        var startEnteredSave = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var completionCommitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var startContext = NewContext();
        await using var completionContext = NewContext();

        var startTask = StockResultProcessor.ProcessAsync(
            startContext, order.Id, startMessageId, "OrderProcessingStarted", OrderState.Processing,
            async () =>
            {
                startEnteredSave.TrySetResult();
                await completionCommitted.Task;
                try
                {
                    return await startContext.SaveChangesOnDbContextAsync(true);
                }
                catch (DbUpdateConcurrencyException ex)
                {
                    throw new Volo.Abp.Data.AbpDbConcurrencyException(ex.Message, ex); // what AbpDbContext does
                }
            });

        await startEnteredSave.Task;

        await StockResultProcessor.ProcessCompletionAsync(
            completionContext, order.Id, order.Id, "OrderProcessed", DateTime.UtcNow,
            () => completionContext.SaveChangesOnDbContextAsync(true));

        completionCommitted.TrySetResult();
        var startOutcome = await startTask;

        Assert.Equal(ResultProcessingOutcome.AlreadyProcessed, startOutcome);
        await using var fresh = NewContext();
        Assert.Equal(OrderState.Completed, (await fresh.Orders.SingleAsync(o => o.Id == order.Id)).State);
    }

    private async Task<Order> SeedOrderAsync(OrderState state)
    {
        // Mirrors OrderStateBehaviourTests: the fixture writes no creation
        // history row (only the API does), so transition-row counts stay clean.
        var order = new Order(Guid.NewGuid(), "key-" + Guid.NewGuid(), "product-1", 1, "corr-" + Guid.NewGuid());
        switch (state)
        {
            case OrderState.Confirmed: order.TransitionTo(OrderState.Confirmed); break;
            case OrderState.Rejected: order.TransitionTo(OrderState.Rejected); break;
            case OrderState.Processing: order.TransitionTo(OrderState.Confirmed); order.TransitionTo(OrderState.Processing); break;
            case OrderState.Completed: order.TransitionTo(OrderState.Confirmed); order.TransitionTo(OrderState.Processing); order.TransitionTo(OrderState.Completed); break;
            case OrderState.PendingStock: break;
            default: throw new ArgumentOutOfRangeException(nameof(state), state, "Unsupported seed state.");
        }

        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesOnDbContextAsync(true);
        return order;
    }

    private OrderServiceDbContext NewContext() =>
        new(new DbContextOptionsBuilder<OrderServiceDbContext>().UseNpgsql(_connectionString).Options);
}

/// <summary>
/// Skips the test unless <c>FLASHSALE_TEST_PG</c> is set, so an environment
/// without a PostgreSQL instance never silently "passes" these tests.
/// </summary>
public sealed class PostgresFactAttribute : FactAttribute
{
    public PostgresFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("FLASHSALE_TEST_PG")))
        {
            Skip = "FLASHSALE_TEST_PG is not set: skipping PostgreSQL race tests. " +
                "Set it to an Npgsql connection string for an admin account to run them.";
        }
    }
}
