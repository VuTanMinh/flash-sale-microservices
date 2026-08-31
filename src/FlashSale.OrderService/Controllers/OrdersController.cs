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
/// Returns as soon as the order + outbox rows commit (state=PendingStock).
/// The OrderPlaced outbox row is written in the SAME SaveChangesAsync call as
/// the order (Week 6) -- one call, one transaction, so the order's existence
/// and its pending OrderPlaced event can never disagree. Actually getting
/// published to RabbitMQ happens later, out-of-band, in
/// BackgroundServices/OutboxPublisherWorker.cs.
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
            // A reused key with a matching payload is a legitimate retry --
            // return the original order. A reused key with a *different*
            // payload means either a client bug or a key collision (two
            // unrelated callers landing on the same key, whether by guessing
            // or bad luck): with no auth model to scope keys per-caller
            // (docs/00-scope-lock.md), the only thing this endpoint can do is
            // refuse to silently hand back someone else's order under a
            // colliding key, rather than merging the two.
            if (existing.ProductId != request.ProductId || existing.Quantity != request.Quantity)
            {
                return Conflict("This Idempotency-Key was already used with a different request.");
            }

            return Ok(ToResponse(existing));
        }

        var order = new Order(Guid.NewGuid(), idempotencyKey, request.ProductId, request.Quantity);
        _dbContext.Orders.Add(order);
        // Same SaveChangesAsync call as the order insert above -- this single
        // fact is the entire point of the Outbox pattern (checklist Step 6.1).
        // Two separate SaveChanges calls here would reintroduce the exact
        // dual-write problem Outbox exists to eliminate: either the order or
        // the "an event needs publishing" fact could commit without the other.
        _dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));
        await _dbContext.SaveChangesAsync();

        return StatusCode(201, ToResponse(order));
    }

    // No ownership check: any caller with the id can read it. Deliberate, not
    // an oversight -- docs/00-scope-lock.md excludes auth/authz entirely, and
    // id is a random GUID, so it functions as an unguessable capability token
    // rather than an enumerable identifier. See report.tex's Limitations
    // chapter for the full reasoning.
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
