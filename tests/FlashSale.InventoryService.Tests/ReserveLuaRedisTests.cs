using System;
using System.Linq;
using System.Threading.Tasks;
using FlashSale.InventoryService.Inventory;
using StackExchange.Redis;
using Xunit;

namespace FlashSale.InventoryService.Tests;

/// <summary>
/// Redis integration tests for scripts/redis/reserve.lua, run through
/// InventoryReservationService.ReserveAsync against a REAL Redis instance.
///
/// The whole reservation decision lives in reserve.lua, which Redis executes
/// atomically: duplicate-check, readiness-check, stock-check, decrement and
/// mark-processed in one EVAL, which is what makes the sequence race-free
/// without any C# locking. InventoryReservationService only loads the script
/// and passes KEYS/ARGV, so proving reserve.lua against a live server proves
/// the reservation itself.
///
/// Isolation: each test instance generates its own product id (a Guid), so its
/// keys <c>inventory:{p}</c>, <c>processed:{p}</c> and <c>sale:open:{p}</c> are
/// unique to that test, and Dispose deletes them. The sale-open marker is set
/// exactly as scripts/warm-up.ps1 sets it (<c>SET sale:open:{p} 1</c>). When
/// <c>FLASHSALE_TEST_REDIS</c> is not set every test is SKIPPED (via
/// <see cref="RedisFactAttribute"/>), never silently passed.
/// </summary>
public class ReserveLuaRedisTests : IDisposable
{
    private readonly IConnectionMultiplexer _redis;
    private readonly InventoryReservationService _service;
    private readonly IDatabase _db;
    private readonly string _productId;

    private string InventoryKey => $"inventory:{_productId}";
    private string ProcessedKey => $"processed:{_productId}";
    private string OpenKey => $"sale:open:{_productId}";

    public ReserveLuaRedisTests()
    {
        // [RedisFact] skips every test when this is missing, so the constructor
        // never runs in that case. The throw is a guard against a mismatch (it
        // is a clear failure, never a silent pass).
        var configuration = Environment.GetEnvironmentVariable("FLASHSALE_TEST_REDIS")
            ?? throw new InvalidOperationException(
                "FLASHSALE_TEST_REDIS is not set; [RedisFact] should have skipped this test. " +
                "Set it to a StackExchange.Redis configuration string, e.g. localhost:6379.");

        _productId = Guid.NewGuid().ToString("N");
        _redis = ConnectionMultiplexer.Connect(configuration);
        _service = new InventoryReservationService(_redis);
        _db = _redis.GetDatabase();
    }

    public void Dispose()
    {
        try
        {
            _db.KeyDelete(new RedisKey[] { InventoryKey, ProcessedKey, OpenKey });
        }
        catch
        {
            // Best-effort: a failed delete must not mask the test result. The
            // Guid-scoped keys keep any leftover data harmless anyway.
        }

        try
        {
            _redis.Dispose();
        }
        catch
        {
            // Best-effort.
        }
    }

    /// <summary>
    /// Sets the product's keys exactly as scripts/warm-up.ps1 opens a sale:
    /// <c>SET inventory:{p} &lt;stock&gt;</c>, <c>DEL processed:{p}</c> and
    /// <c>SET sale:open:{p} 1</c>.
    /// </summary>
    private async Task OpenSaleAsync(int stock)
    {
        await _db.StringSetAsync(InventoryKey, stock);
        await _db.KeyDeleteAsync(ProcessedKey);
        await _db.StringSetAsync(OpenKey, "1");
    }

    private async Task<int> GetStockAsync()
    {
        var value = await _db.StringGetAsync(InventoryKey);
        return (int)value;
    }

    /// <summary>
    /// Case (a): sale open with stock 2 -> Reserved, stock decremented to 1 and
    /// the order recorded in the processed set.
    /// </summary>
    [RedisFact]
    public async Task Open_sale_with_stock_reserves_and_decrements()
    {
        await OpenSaleAsync(2);
        var orderId = Guid.NewGuid().ToString("N");

        var result = await _service.ReserveAsync(_productId, orderId);

        Assert.Equal(ReservationResult.Reserved, result);
        Assert.Equal(1, await GetStockAsync());
        Assert.True(await _db.SetContainsAsync(ProcessedKey, orderId));
    }

    /// <summary>
    /// Case (b): the same order reserved again -> Duplicate, and stock is left
    /// unchanged (the duplicate check runs before the decrement).
    /// </summary>
    [RedisFact]
    public async Task Same_order_again_is_duplicate_and_does_not_decrement()
    {
        await OpenSaleAsync(2);
        var orderId = Guid.NewGuid().ToString("N");

        Assert.Equal(ReservationResult.Reserved, await _service.ReserveAsync(_productId, orderId));
        Assert.Equal(1, await GetStockAsync());

        Assert.Equal(ReservationResult.Duplicate, await _service.ReserveAsync(_productId, orderId));
        Assert.Equal(1, await GetStockAsync());
    }

    /// <summary>
    /// Case (c): sale open but stock 0 -> Rejected, and nothing changes (stock
    /// still 0, order NOT in the processed set).
    /// </summary>
    [RedisFact]
    public async Task Zero_stock_rejects_and_changes_nothing()
    {
        await OpenSaleAsync(0);
        var orderId = Guid.NewGuid().ToString("N");

        var result = await _service.ReserveAsync(_productId, orderId);

        Assert.Equal(ReservationResult.Rejected, result);
        Assert.Equal(0, await GetStockAsync());
        Assert.False(await _db.SetContainsAsync(ProcessedKey, orderId));
    }

    /// <summary>
    /// Case (d): stock exists but the sale-open marker is missing -> NotOpen,
    /// stock unchanged and the order NOT recorded (readiness is checked before
    /// any reservation).
    /// </summary>
    [RedisFact]
    public async Task Missing_open_marker_is_not_open()
    {
        await _db.StringSetAsync(InventoryKey, 2);
        var orderId = Guid.NewGuid().ToString("N");

        var result = await _service.ReserveAsync(_productId, orderId);

        Assert.Equal(ReservationResult.NotOpen, result);
        Assert.Equal(2, await GetStockAsync());
        Assert.False(await _db.SetContainsAsync(ProcessedKey, orderId));
    }

    /// <summary>
    /// Case (e): stock 3 with 10 different orders reserving concurrently ->
    /// exactly 3 Reserved and 7 Rejected, stock drained to 0 and the processed
    /// set holding exactly the 3 winners (the Lua atomicity makes this
    /// deterministic, not a timing accident).
    /// </summary>
    [RedisFact]
    public async Task Ten_concurrent_orders_reserve_exactly_the_available_stock()
    {
        await OpenSaleAsync(3);
        var orderIds = Enumerable.Range(0, 10).Select(_ => Guid.NewGuid().ToString("N")).ToArray();

        var results = await Task.WhenAll(orderIds.Select(id => _service.ReserveAsync(_productId, id)));

        Assert.Equal(3, results.Count(r => r == ReservationResult.Reserved));
        Assert.Equal(7, results.Count(r => r == ReservationResult.Rejected));
        Assert.Equal(0, await GetStockAsync());
        Assert.Equal(3, (int)await _db.SetLengthAsync(ProcessedKey));
    }
}

/// <summary>
/// Skips the test unless <c>FLASHSALE_TEST_REDIS</c> is set, so an environment
/// without a Redis instance never silently "passes" these tests.
/// </summary>
public sealed class RedisFactAttribute : FactAttribute
{
    public RedisFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("FLASHSALE_TEST_REDIS")))
        {
            Skip = "FLASHSALE_TEST_REDIS is not set: skipping Redis reservation tests. " +
                "Set it to a StackExchange.Redis configuration string (e.g. localhost:6379) to run them.";
        }
    }
}
