using System;
using System.Linq;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FlashSale.OrderService.Tests;

/// <summary>
/// Proves the actual claim behind the Transactional Outbox pattern (checklist
/// Step 6.1): the order insert and its OrderPlaced outbox row live in one
/// SaveChangesAsync call, so if the outbox insert fails for any reason, the
/// order insert rolls back with it -- there is no way for an order to exist
/// in the database without a corresponding pending event, or vice versa.
///
/// Uses a real SQLite in-memory database rather than a mock or EF Core's
/// InMemory provider on purpose: InMemory doesn't enforce relational
/// constraints (a duplicate primary key wouldn't even throw), so it can't
/// actually demonstrate a rollback -- only a real transactional engine can.
/// SQLite is a real engine and is fast enough to spin up fresh per test.
/// </summary>
public class OutboxAtomicityTests : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public OutboxAtomicityTests()
    {
        // SQLite's in-memory database is destroyed when its connection closes,
        // so the connection must be opened and held for the test's lifetime,
        // not created fresh per DbContext instance.
        _connection = new SqliteConnection("DataSource=:memory:");
        _connection.Open();

        var options = new DbContextOptionsBuilder<OrderServiceDbContext>()
            .UseSqlite(_connection)
            .Options;

        _dbContext = new OrderServiceDbContext(options);
        _dbContext.Database.EnsureCreated();
    }

    // AbpDbContext.SaveChangesAsync wraps EF Core's own SaveChangesAsync with
    // ABP concepts (audit logging, entity-change events, distributed event
    // dispatch) that are resolved through the ABP DI container -- none of
    // which exists here, since this test constructs the DbContext directly
    // rather than through a full ABP application host. SaveChangesOnDbContextAsync
    // is ABP's own documented escape hatch for exactly this: it calls EF
    // Core's base.SaveChangesAsync directly, which is the actual thing this
    // test is about (transactional atomicity), not ABP's auditing pipeline.
    private Task<int> SaveChangesAsync() => _dbContext.SaveChangesOnDbContextAsync(true);

    public void Dispose()
    {
        _dbContext.Dispose();
        _connection.Dispose();
    }

    [Fact]
    public async Task Order_and_outbox_row_both_commit_in_one_SaveChanges_call()
    {
        var order = new Order(Guid.NewGuid(), "idem-key-1", "product-1", 1, "corr-1");
        _dbContext.Orders.Add(order);
        _dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));

        await SaveChangesAsync();

        Assert.True(await _dbContext.Orders.AnyAsync(o => o.Id == order.Id));
        Assert.True(await _dbContext.OutboxEvents.AnyAsync(e => e.OrderId == order.Id));
    }

    [Fact]
    public async Task Failed_outbox_insert_rolls_back_the_order_insert_too()
    {
        // Seed a pre-existing outbox row so we have a real primary key to collide with.
        var priorOrder = new Order(Guid.NewGuid(), "idem-key-0", "product-1", 1, "corr-0");
        var priorOutboxEvent = OutboxEvent.ForOrderPlaced(priorOrder);
        _dbContext.Orders.Add(priorOrder);
        _dbContext.OutboxEvents.Add(priorOutboxEvent);
        await SaveChangesAsync();

        // Attempt the collision through a SEPARATE DbContext instance (same
        // connection/database). Reusing _dbContext here would make EF Core's
        // own in-memory change tracker reject the duplicate key immediately,
        // before any SQL is even sent -- that would prove the tracker works,
        // not that the pattern is atomic. A fresh context has no memory of
        // priorOutboxEvent, so the duplicate can only be caught where this
        // test actually needs it caught: by the database's own primary key
        // constraint, inside a real transaction.
        await using var collisionDbContext = new OrderServiceDbContext(
            new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);

        // A new order whose outbox row (by construction, simulating a bug
        // that reused an id) collides on the outbox table's primary key.
        var newOrder = new Order(Guid.NewGuid(), "idem-key-1", "product-1", 1, "corr-1");
        var collidingOutboxEvent = new OutboxEvent(
            priorOutboxEvent.Id, // <- reuses an existing primary key on purpose
            newOrder.Id,
            "OrderPlaced",
            "{}");

        collisionDbContext.Orders.Add(newOrder);
        collisionDbContext.OutboxEvents.Add(collidingOutboxEvent);

        await Assert.ThrowsAsync<DbUpdateException>(
            () => collisionDbContext.SaveChangesOnDbContextAsync(true));

        // The whole point of the pattern: the failed outbox insert must have
        // rolled back the order insert too, in the same call. Query with a
        // fresh context (not the one whose failed SaveChanges left tracked
        // entities in a stale state) to confirm what's actually in the database.
        await using var freshDbContext = new OrderServiceDbContext(
            new DbContextOptionsBuilder<OrderServiceDbContext>().UseSqlite(_connection).Options);

        var persistedNewOrder = await freshDbContext.Orders.FirstOrDefaultAsync(o => o.Id == newOrder.Id);
        Assert.Null(persistedNewOrder);

        // Sanity check: the prior, unrelated order from the successful first
        // SaveChanges call is still there -- the rollback only undid the
        // failed transaction, not everything in the database.
        Assert.True(await freshDbContext.Orders.AnyAsync(o => o.Id == priorOrder.Id));
    }
}
