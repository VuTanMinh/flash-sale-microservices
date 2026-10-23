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
/// The end-to-end admission bound added after the external review of Week 12:
/// the estimate the gate reads (shared with the Outbox-backlog bound) and the
/// set of orders it counts as in flight. The runtime behaviour (503
/// reason=inflight, release when orders finish) is case I of
/// scripts/verify-load-shedding.ps1.
/// </summary>
public class InFlightAdmissionTests : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly OrderServiceDbContext _dbContext;

    public InFlightAdmissionTests()
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
    public void Estimate_is_the_measured_count_plus_accepts_since_and_keeps_an_accept_made_during_the_query()
    {
        var monitor = new InFlightOrdersMonitor();
        Assert.Equal(0, monitor.InFlight); // unknown before the first measurement: admit

        monitor.RecordAccepted();
        monitor.RecordAccepted();
        Assert.Equal(2, monitor.InFlight); // seen at once, before any measurement

        var snapshot = monitor.SnapshotAccepted(); // the measurement starts: 2 accepts it will see
        monitor.RecordAccepted();                  // accepted while the count query runs
        monitor.Publish(count: 2, acceptedSnapshot: snapshot);
        Assert.Equal(3, monitor.InFlight);         // 2 measured + the 1 the query could not see

        monitor.Publish(count: 0, acceptedSnapshot: monitor.SnapshotAccepted()); // everything finished
        Assert.Equal(0, monitor.InFlight);
    }

    [Fact]
    public void Outbox_backlog_and_in_flight_estimates_are_independent()
    {
        var backlog = new OutboxBacklogMonitor();
        var inFlight = new InFlightOrdersMonitor();
        backlog.RecordAccepted();
        Assert.Equal(1, backlog.Unpublished);
        Assert.Equal(0, inFlight.InFlight);
    }

    [Fact]
    public async Task Only_PendingStock_Confirmed_and_Processing_orders_are_in_flight()
    {
        foreach (var state in Enum.GetValues<OrderState>().Where(s => s != OrderState.ProcessingFailed))
        {
            _dbContext.Orders.Add(OrderIn(state));
        }
        await _dbContext.SaveChangesOnDbContextAsync(true);

        var states = (await InFlightOrdersMonitor.WhereInFlight(_dbContext.Orders).Select(o => o.State).ToListAsync())
            .OrderBy(s => s).ToArray();

        Assert.Equal([OrderState.PendingStock, OrderState.Confirmed, OrderState.Processing], states);
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
}
