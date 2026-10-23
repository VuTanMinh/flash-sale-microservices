using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FlashSale.OrderService.Messaging;

/// <summary>
/// C3 end-to-end admission bound (added after the external review of Week 12):
/// the number of orders accepted but not yet Completed or Rejected. The
/// Outbox-backlog bound only protects the first hop; during the TP-L04
/// overload Order Service accepted about 13 orders/s while the Process Worker
/// finishes about 3.7/s, so work piled up downstream and took about 105 s to
/// clear. Bounding the unfinished orders refuses at the door what the slowest
/// stage cannot absorb. See <see cref="AdmissionCountEstimate"/>.
/// </summary>
public sealed class InFlightOrdersMonitor : AdmissionCountEstimate
{
    /// <summary>The current estimate of orders not yet in a terminal state.</summary>
    public int InFlight => Current;

    /// <summary>
    /// The orders counted as in flight: PendingStock, Confirmed or Processing.
    /// Completed and Rejected are terminal; ProcessingFailed is terminal and
    /// unreachable.
    /// </summary>
    public static IQueryable<Order> WhereInFlight(IQueryable<Order> orders) =>
        orders.Where(o => o.State == OrderState.PendingStock || o.State == OrderState.Confirmed || o.State == OrderState.Processing);
}

/// <summary>
/// Measures the in-flight count every Admission:InFlightRefreshMilliseconds and
/// publishes it to <see cref="InFlightOrdersMonitor"/>. Runs only when
/// admission is enabled with MaxInFlightOrders &gt; 0, so C2 pays nothing. A
/// failed measurement keeps the last estimate, which only grows with new
/// accepts until the next success -- the bound errs towards refusing, never
/// towards admitting past it.
/// </summary>
public class InFlightOrdersRefresher : BackgroundService
{
    private readonly AdmissionOptions _options;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly InFlightOrdersMonitor _monitor;
    private readonly ILogger<InFlightOrdersRefresher> _logger;

    public InFlightOrdersRefresher(
        IOptions<AdmissionOptions> options, IServiceScopeFactory scopeFactory, InFlightOrdersMonitor monitor,
        ILogger<InFlightOrdersRefresher> logger)
    {
        _options = options.Value;
        _scopeFactory = scopeFactory;
        _monitor = monitor;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled || _options.MaxInFlightOrders <= 0)
        {
            return;
        }

        var interval = TimeSpan.FromMilliseconds(Math.Max(100, _options.InFlightRefreshMilliseconds));
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<OrderServiceDbContext>();
                var snapshot = _monitor.SnapshotAccepted();
                var count = await InFlightOrdersMonitor.WhereInFlight(dbContext.Orders).CountAsync(stoppingToken);
                _monitor.Publish(count, snapshot);
                OrderMetrics.InFlightOrders.Set(count);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning(ex, "In-flight order count refresh failed; keeping the last estimate");
            }

            try
            {
                await Task.Delay(interval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
        }
    }
}
