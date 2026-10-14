using Npgsql;

namespace FlashSale.OrderService.Experiments.C0Naive;

/// <summary>
/// Deliberately broken: reads current stock, checks it in application code,
/// then issues a separate UPDATE — two round trips, no locking. This exists
/// once, to capture the over-selling bug as log evidence for the report
/// (checklist Step 3.2), then is never touched again.
///
/// NOT reachable via HTTP. Invoked only via `dotnet run -- --run-c0-demo`
/// (see Program.cs) — it never registers a route, so a stray request later
/// in the project can't hit it.
/// </summary>
public static class C0NaiveDemo
{
    private const string ProductId = "c0-demo-product";

    public static async Task RunAsync(string connectionString, int concurrentRequests = 5)
    {
        await SeedAsync(connectionString);

        Console.WriteLine($"[C0] Seeded '{ProductId}' with stock = 1. Firing {concurrentRequests} concurrent naive requests...");

        // A shared gate so every attempt actually reaches the read at the same
        // instant, instead of relying on Task.WhenAll's scheduling to happen to
        // overlap. Without this, the race window (~50ms) can outrun how long it
        // takes the scheduler to start every task, and the bug won't reproduce
        // on every run.
        var startGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var tasks = Enumerable.Range(1, concurrentRequests)
            .Select(i => AttemptOneAsync(connectionString, i, startGate.Task))
            .ToArray();

        await Task.Delay(200); // let every attempt open its connection and start waiting on the gate
        startGate.SetResult();

        var results = await Task.WhenAll(tasks);

        var confirmed = results.Count(r => r);
        Console.WriteLine($"[C0] Result: {confirmed} of {concurrentRequests} concurrent requests got 'Confirmed' for a product seeded with stock = 1.");
        Console.WriteLine(confirmed > 1
            ? "[C0] OVER-SOLD: more than one request reserved the same single unit of stock. This is the bug C1 (Step 3.3) fixes."
            : "[C0] Did not reproduce this run — the race window may need widening (see the Task.Delay in AttemptOneAsync). Re-run.");

        var finalStock = await ReadStockAsync(connectionString);
        Console.WriteLine($"[C0] Final stock in database: {finalStock} (started at 1).");
    }

    private static async Task<bool> AttemptOneAsync(string connectionString, int attemptNumber, Task startGate)
    {
        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();

        await startGate;

        // Round trip #1: read current stock.
        int stock;
        await using (var readCmd = new NpgsqlCommand(
            "SELECT stock FROM order_service.inventory WHERE product_id = @p", connection))
        {
            readCmd.Parameters.AddWithValue("p", ProductId);
            stock = (int)(await readCmd.ExecuteScalarAsync())!;
        }

        // Deliberately widen the race window so the bug reproduces reliably
        // on every run instead of depending on unlucky timing.
        await Task.Delay(50);

        if (stock <= 0)
        {
            await LogResultAsync(connection, "Rejected");
            Console.WriteLine($"[C0] Attempt {attemptNumber}: saw stock={stock}, Rejected.");
            return false;
        }

        // Round trip #2: separate write, unconditional on the value just read.
        await using (var writeCmd = new NpgsqlCommand(
            "UPDATE order_service.inventory SET stock = stock - 1 WHERE product_id = @p", connection))
        {
            writeCmd.Parameters.AddWithValue("p", ProductId);
            await writeCmd.ExecuteNonQueryAsync();
        }

        await LogResultAsync(connection, "Confirmed");
        Console.WriteLine($"[C0] Attempt {attemptNumber}: saw stock={stock}, Confirmed.");
        return true;
    }

    private static async Task SeedAsync(string connectionString)
    {
        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO order_service.inventory (product_id, stock) VALUES (@p, 1) " +
            "ON CONFLICT (product_id) DO UPDATE SET stock = 1",
            connection);
        cmd.Parameters.AddWithValue("p", ProductId);
        await cmd.ExecuteNonQueryAsync();
    }

    private static async Task<int> ReadStockAsync(string connectionString)
    {
        await using var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync();
        await using var cmd = new NpgsqlCommand(
            "SELECT stock FROM order_service.inventory WHERE product_id = @p", connection);
        cmd.Parameters.AddWithValue("p", ProductId);
        return (int)(await cmd.ExecuteScalarAsync())!;
    }

    private static async Task LogResultAsync(NpgsqlConnection connection, string result)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO order_service.baseline_orders (config, product_id, result) VALUES ('C0', @p, @r)",
            connection);
        cmd.Parameters.AddWithValue("p", ProductId);
        cmd.Parameters.AddWithValue("r", result);
        await cmd.ExecuteNonQueryAsync();
    }
}
