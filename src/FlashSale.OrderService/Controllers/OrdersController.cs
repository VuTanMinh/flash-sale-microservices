using System;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Volo.Abp.AspNetCore.Mvc;

namespace FlashSale.OrderService.Controllers;

/// <summary>
/// The real order API (Week 5) — idempotent creation and status lookup.
/// This is the canonical /api/orders; C1's baseline comparison lives at
/// /api/c1/orders (BaselineOrdersController) so both configurations stay
/// independently reachable for Week 13/14 experiments.
///
/// Currently returns as soon as the order row commits (state=PendingStock) —
/// there is no event publication yet (that's the Transactional Outbox, Week 6),
/// so nothing will ever move this order past PendingStock until then. That's
/// expected for this week, not a bug to chase.
/// </summary>
[Route("api/orders")]
public class OrdersController : AbpController
{
    private readonly OrderServiceDbContext _dbContext;

    public OrdersController(OrderServiceDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public record CreateOrderRequest(string ProductId, int Quantity);

    public record OrderResponse(
        Guid Id,
        string ProductId,
        int Quantity,
        string State,
        DateTime RequestAcceptedAt,
        DateTime? ConfirmedOrRejectedAt,
        DateTime? CompletedAt);

    [HttpPost]
    public async Task<ActionResult<OrderResponse>> CreateOrderAsync(
        [FromBody] CreateOrderRequest request,
        [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey)
    {
        if (string.IsNullOrWhiteSpace(idempotencyKey))
        {
            return BadRequest("The Idempotency-Key header is required.");
        }

        // Client-facing idempotency (Week 5) -- distinct from the broker-message
        // idempotency the Week 9 Inbox pattern adds later. This dedupes an
        // impatient client retrying the same submission, not a redelivered
        // message; see docs/00-scope-lock.md's boundary note.
        var existing = await _dbContext.Orders
            .FirstOrDefaultAsync(o => o.IdempotencyKey == idempotencyKey);

        if (existing is not null)
        {
            return Ok(ToResponse(existing));
        }

        var order = new Order(Guid.NewGuid(), idempotencyKey, request.ProductId, request.Quantity);
        _dbContext.Orders.Add(order);
        await _dbContext.SaveChangesAsync();

        return StatusCode(201, ToResponse(order));
    }

    [HttpGet("{id}")]
    public async Task<ActionResult<OrderResponse>> GetOrderAsync(Guid id)
    {
        var order = await _dbContext.Orders.FindAsync(id);
        if (order is null)
        {
            return NotFound();
        }

        return Ok(ToResponse(order));
    }

    private static OrderResponse ToResponse(Order order) => new(
        order.Id,
        order.ProductId,
        order.Quantity,
        order.State.ToString(),
        order.RequestAcceptedAt,
        order.ConfirmedOrRejectedAt,
        order.CompletedAt);
}
