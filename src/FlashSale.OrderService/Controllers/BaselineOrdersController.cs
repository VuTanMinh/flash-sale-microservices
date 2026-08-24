using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Npgsql;
using Volo.Abp.AspNetCore.Mvc;

namespace FlashSale.OrderService.Controllers;

/// <summary>
/// C1 — the PostgreSQL atomic-update baseline (checklist Step 3.3), and the
/// main baseline benchmarked against the real async design all semester.
///
/// A single conditional `UPDATE ... WHERE stock >= 1 RETURNING stock` is one
/// round trip and provably atomic — unlike C0's separate read-then-write, two
/// concurrent requests for the last unit of stock can't both see a stale
/// value and both succeed, because the WHERE clause is (re-)evaluated by
/// Postgres against the current row inside its own lock, not against
/// something the application read earlier. The order-log insert commits in
/// the same transaction as the stock update, so the two never disagree.
///
/// Route moved off /api/orders in Week 5: that path now belongs to the real,
/// idempotent, event-driven design (OrdersController) that C1 exists to be
/// compared against all semester (Week 13/14 experiments need both
/// configurations independently reachable, not one path whose behavior
/// depends on a hidden flag).
/// </summary>
[Route("api/c1/orders")]
public class BaselineOrdersController : AbpController
{
    private readonly string _connectionString;

    public BaselineOrdersController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("Default")!;
    }

    public record PlaceOrderRequest(string ProductId);
    public record PlaceOrderResponse(string ProductId, string Result, int? RemainingStock);

    [HttpPost]
    public async Task<PlaceOrderResponse> PlaceOrderAsync([FromBody] PlaceOrderRequest request)
    {
        await using var connection = new NpgsqlConnection(_connectionString);
        await connection.OpenAsync();
        await using var transaction = await connection.BeginTransactionAsync();

        int? remainingStock = null;
        await using (var updateCmd = new NpgsqlCommand(
            """
            UPDATE order_service.inventory
            SET stock = stock - 1
            WHERE product_id = @p AND stock >= 1
            RETURNING stock
            """, connection, transaction))
        {
            updateCmd.Parameters.AddWithValue("p", request.ProductId);
            var result = await updateCmd.ExecuteScalarAsync();
            if (result is int stock)
            {
                remainingStock = stock;
            }
        }

        var outcome = remainingStock is not null ? "Confirmed" : "Rejected";

        await using (var logCmd = new NpgsqlCommand(
            "INSERT INTO order_service.baseline_orders (config, product_id, result) VALUES ('C1', @p, @r)",
            connection, transaction))
        {
            logCmd.Parameters.AddWithValue("p", request.ProductId);
            logCmd.Parameters.AddWithValue("r", outcome);
            await logCmd.ExecuteNonQueryAsync();
        }

        await transaction.CommitAsync();

        return new PlaceOrderResponse(request.ProductId, outcome, remainingStock);
    }
}
