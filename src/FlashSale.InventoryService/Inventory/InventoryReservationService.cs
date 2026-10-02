using System;
using System.IO;
using System.Threading.Tasks;
using StackExchange.Redis;

namespace FlashSale.InventoryService.Inventory;

/// <summary>
/// Thin wrapper around the actual reservation logic, which lives entirely in
/// scripts/redis/reserve.lua (linked into this project's build output, not
/// copied -- see the .csproj comment). Redis executes Lua scripts atomically
/// (single-threaded), which is what makes the duplicate-check +
/// stock-check + decrement + mark-processed sequence race-free without any
/// locking on this side -- this class does not, and must not, reimplement
/// any of that logic in C#; it only loads the script text and passes
/// through KEYS/ARGV.
/// </summary>
public class InventoryReservationService
{
    private readonly IConnectionMultiplexer _redis;
    private readonly string _script;

    public InventoryReservationService(IConnectionMultiplexer redis)
    {
        _redis = redis;

        var scriptPath = Path.Combine(AppContext.BaseDirectory, "Redis", "reserve.lua");
        _script = File.ReadAllText(scriptPath);
    }

    public async Task<ReservationResult> ReserveAsync(string productId, string orderId)
    {
        var db = _redis.GetDatabase();

        var result = await db.ScriptEvaluateAsync(
            _script,
            keys: [$"inventory:{productId}", $"processed:{productId}", $"sale:open:{productId}"],
            values: [orderId]);

        var resultString = (string)result!;
        return resultString switch
        {
            "RESERVED" => ReservationResult.Reserved,
            "DUPLICATE" => ReservationResult.Duplicate,
            "REJECTED" => ReservationResult.Rejected,
            "NOT_OPEN" => ReservationResult.NotOpen,
            _ => throw new InvalidOperationException($"Unexpected reserve.lua result: '{resultString}'"),
        };
    }
}
