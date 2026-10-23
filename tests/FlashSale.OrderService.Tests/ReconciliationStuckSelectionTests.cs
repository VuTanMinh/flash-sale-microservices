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
/// External review after Week 12: reconciliation only watched PendingStock, so
/// an order whose Worker events were lost stayed Confirmed or Processing for
/// ever. ReconciliationWorker.WhereStuck now selects those too, timed from the
/// stock confirmation against the longer ProcessingStuckTimeoutSeconds.
/// Instead of ageing rows, the test moves "now" forward from the moment the
/// orders were written. Real SQLite engine, as in OrderStateBehaviourTests.
/// </summary>
public class ReconciliationStuckSelectionTests : IDisposable
{
    private static readonly ReconciliationOptions Options = new() { StuckTimeoutSeconds = 30, ProcessingStuckTimeoutSeconds = 300 };

    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public ReconciliationStuckSelectionTests()
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
    public async Task PendingStock_is_stuck_after_the_short_timeout_and_Confirmed_or_Processing_after_the_processing_timeout()
    {
        var written = DateTime.UtcNow;
        foreach (var state in Enum.GetValues<OrderState>().Where(s => s != OrderState.ProcessingFailed))
        {
            _dbContext.Orders.Add(OrderIn(state));
        }
        await _dbContext.SaveChangesOnDbContextAsync(true);

        Assert.Empty(await StuckStatesAt(written.AddSeconds(10)));
        Assert.Equal([OrderState.PendingStock], await StuckStatesAt(written.AddSeconds(60)));
        Assert.Equal(
            [OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing],
            await StuckStatesAt(written.AddSeconds(400)));
    }

    [Fact]
    public async Task Processing_timeout_is_never_shorter_than_the_PendingStock_timeout()
    {
        // StuckTimeoutSeconds = 3600 is how every verifier that does not test
        // reconciliation turns it off; a shorter ProcessingStuckTimeoutSeconds
        // must not switch the Confirmed/Processing sweep back on.
        var off = new ReconciliationOptions { StuckTimeoutSeconds = 3600, ProcessingStuckTimeoutSeconds = 300 };
        var written = DateTime.UtcNow;
        _dbContext.Orders.Add(OrderIn(OrderState.Confirmed));
        _dbContext.Orders.Add(OrderIn(OrderState.Processing));
        await _dbContext.SaveChangesOnDbContextAsync(true);

        Assert.Empty(await StuckStatesAt(written.AddSeconds(400), off));
        Assert.Equal([OrderState.Confirmed, OrderState.Processing], await StuckStatesAt(written.AddSeconds(3700), off));
    }

    private async Task<OrderState[]> StuckStatesAt(DateTime now, ReconciliationOptions? options = null) =>
        (await ReconciliationWorker.WhereStuck(_dbContext.Orders, now, options ?? Options).Select(o => o.State).ToListAsync())
        .OrderBy(s => s).ToArray();

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
}
