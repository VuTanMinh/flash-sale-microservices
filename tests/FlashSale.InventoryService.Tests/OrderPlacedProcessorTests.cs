using System;
using System.Reflection;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.InventoryService.Data;
using FlashSale.InventoryService.Entities;
using FlashSale.InventoryService.Inventory;
using FlashSale.InventoryService.Messaging;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using StackExchange.Redis;
using Xunit;

namespace FlashSale.InventoryService.Tests;

/// <summary>
/// Tests OrderPlacedProcessor.ProcessAsync, the idempotent core of Inventory
/// Service's OrderPlaced handling, focusing on the Week 14 NOT_OPEN undersell
/// fix: the stored result is looked up BEFORE any Redis reservation, so a
/// re-triggered OrderPlaced for an order that already has a result row must
/// never call reserve.lua again.
///
/// "Redis is never called" is proven by constructing InventoryReservationService
/// over an IConnectionMultiplexer DispatchProxy whose every member throws, so
/// any path that reaches ReserveAsync -> ScriptEvaluateAsync fails the test.
///
/// Uses a real SQLite in-memory database (not EF Core's InMemory provider) for
/// the same reason as FlashSale.OrderService.Tests: the unique index on
/// OutboxEvent.OrderId is the actual idempotency mechanism under test.
/// </summary>
public class OrderPlacedProcessorTests : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly InventoryServiceDbContext _dbContext;

    public OrderPlacedProcessorTests()
    {
        // SQLite's in-memory database is destroyed when its connection closes,
        // so the connection must be opened and held for the test's lifetime.
        _connection = new SqliteConnection("DataSource=:memory:");
        _connection.Open();

        var options = new DbContextOptionsBuilder<InventoryServiceDbContext>()
            .UseSqlite(_connection)
            .Options;

        _dbContext = new InventoryServiceDbContext(options);
        _dbContext.Database.EnsureCreated();
    }

    public void Dispose()
    {
        _dbContext.Dispose();
        _connection.Dispose();
    }

    private static OrderPlacedEto OrderPlaced(Guid orderId, Guid messageId) =>
        new()
        {
            OrderId = orderId,
            ProductId = "product-1",
            Quantity = 1,
            MessageId = messageId,
            CorrelationId = "corr-" + Guid.NewGuid(),
        };

    private static InventoryReservationService ThrowingReservationService() =>
        new(DispatchProxy.Create<IConnectionMultiplexer, ThrowingConnectionMultiplexerProxy>());

    // The injectable save overload exists so a test can substitute AbpDbContext's
    // SaveChangesOnDbContextAsync bypass for the real, DI-backed SaveChangesAsync
    // (a directly-constructed DbContext has no ABP container) -- see
    // FlashSale.OrderService.Tests.OutboxAtomicityTests for the fuller reasoning.
    private Task<OrderPlacedProcessingOutcome> ProcessAsync(Guid orderId, Guid messageId) =>
        OrderPlacedProcessor.ProcessAsync(
            _dbContext, ThrowingReservationService(), OrderPlaced(orderId, messageId), NullLogger.Instance,
            () => _dbContext.SaveChangesOnDbContextAsync(true));

    [Fact]
    public async Task Inbox_already_has_MessageId_returns_AlreadyProcessed_and_never_reserves()
    {
        var orderId = Guid.NewGuid();
        var messageId = Guid.NewGuid();
        _dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), messageId, "OrderPlaced"));
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var outcome = await ProcessAsync(orderId, messageId);

        Assert.Equal(OrderPlacedProcessingOutcome.AlreadyProcessed, outcome);

        await using var fresh = FreshDbContext();
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
        // No reservation ran, so no result row exists for this order.
        Assert.Equal(0, await fresh.OutboxEvents.CountAsync(e => e.OrderId == orderId));
    }

    [Fact]
    public async Task Stored_published_StockRejected_result_is_requeued_without_reserving()
    {
        var orderId = Guid.NewGuid();
        var messageId = Guid.NewGuid();

        var stored = new OutboxEvent(Guid.NewGuid(), orderId, "StockRejected", "{}");
        stored.MarkPublished(DateTime.UtcNow);
        _dbContext.OutboxEvents.Add(stored);
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var outcome = await ProcessAsync(orderId, messageId);

        Assert.Equal(OrderPlacedProcessingOutcome.Applied, outcome);

        await using var fresh = FreshDbContext();
        var row = await fresh.OutboxEvents.SingleAsync(e => e.OrderId == orderId);
        Assert.Equal("StockRejected", row.EventType);
        // MarkForRepublish cleared the flag -> the row is re-queued.
        Assert.False(row.Published);
        Assert.Null(row.PublishedAt);
        // Still exactly one result row: no reservation ran, no new row written.
        Assert.Equal(1, await fresh.OutboxEvents.CountAsync(e => e.OrderId == orderId));
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
    }

    [Fact]
    public async Task Stored_unpublished_result_is_left_alone_without_reserving()
    {
        var orderId = Guid.NewGuid();
        var messageId = Guid.NewGuid();

        _dbContext.OutboxEvents.Add(new OutboxEvent(Guid.NewGuid(), orderId, "StockRejected", "{}"));
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var outcome = await ProcessAsync(orderId, messageId);

        Assert.Equal(OrderPlacedProcessingOutcome.Applied, outcome);

        await using var fresh = FreshDbContext();
        var row = await fresh.OutboxEvents.SingleAsync(e => e.OrderId == orderId);
        // Left for the outbox publisher: untouched.
        Assert.False(row.Published);
        Assert.Null(row.PublishedAt);
        // No new result row.
        Assert.Equal(1, await fresh.OutboxEvents.CountAsync(e => e.OrderId == orderId));
        Assert.Equal(1, await fresh.ProcessedMessages.CountAsync(m => m.MessageId == messageId));
    }

    private InventoryServiceDbContext FreshDbContext() =>
        new(new DbContextOptionsBuilder<InventoryServiceDbContext>().UseSqlite(_connection).Options);
}

/// <summary>
/// Every IConnectionMultiplexer member throws, so any use of Redis fails the
/// test loudly: the only thing InventoryReservationService does at construction
/// is read its Lua script file, so the proxy is never touched unless a
/// reservation actually runs.
/// </summary>
public class ThrowingConnectionMultiplexerProxy : DispatchProxy
{
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) =>
        throw new InvalidOperationException("Redis must not be used in this test.");
}
