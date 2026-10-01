using System;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using FlashSale.OrderService.Messaging;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Volo.Abp.AspNetCore.Mvc;
using Volo.Abp.Tracing;

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
    private readonly ICorrelationIdProvider _correlationIdProvider;

    public OrdersController(OrderServiceDbContext dbContext, ICorrelationIdProvider correlationIdProvider)
    {
        _dbContext = dbContext;
        _correlationIdProvider = correlationIdProvider;
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

    // Documented outcomes (exported to docs/api-contract-v1.json): 201 new
    // order, 200 replay of the same Idempotency-Key + payload, 400 missing
    // key, 409 key reused with a different payload.
    [HttpPost]
    [ProducesResponseType(typeof(OrderResponse), StatusCodes.Status201Created)]
    [ProducesResponseType(typeof(OrderResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<OrderResponse>> CreateOrderAsync(
        [FromBody] CreateOrderRequest request,
        [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey)
    {
        if (string.IsNullOrWhiteSpace(idempotencyKey))
        {
            return BadRequest("The Idempotency-Key header is required.");
        }

        // Week 11, Step 11.2. Deliberately ABP's correlation id rather than
        // one minted here: app.UseCorrelationId() (OrderServiceModule) already
        // reads the caller's X-Correlation-Id header or generates one per HTTP
        // request, and app.UseAbpSerilogEnrichers() already stamps THAT value
        // onto every log line written during the request. Generating a second
        // id here would mean the HTTP log lines and the order row disagreed
        // about what this request is called -- which is precisely the failure
        // this step exists to prevent. Taking ABP's value instead makes the
        // id continuous from the inbound request, through the events below,
        // to the other two services.
        var correlationId = _correlationIdProvider.Get()
            ?? throw new InvalidOperationException("No correlation id available from ICorrelationIdProvider.");

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

        var order = new Order(Guid.NewGuid(), idempotencyKey, request.ProductId, request.Quantity, correlationId);
        _dbContext.Orders.Add(order);
        // Same SaveChangesAsync call as the order insert above -- this single
        // fact is the entire point of the Outbox pattern (checklist Step 6.1).
        // Two separate SaveChanges calls here would reintroduce the exact
        // dual-write problem Outbox exists to eliminate: either the order or
        // the "an event needs publishing" fact could commit without the other.
        _dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));
        await _dbContext.SaveChangesAsync();

        // Counted only after the commit, not before: an order that failed to
        // persist was never accepted, and Week 13/14 compare this counter
        // against JMeter's own request count to detect exactly that kind of
        // divergence.
        OrderMetrics.OrdersAccepted.Inc();

        return StatusCode(201, ToResponse(order));
    }

    // No ownership check: any caller with the id can read it. Deliberate, not
    // an oversight -- docs/00-scope-lock.md excludes auth/authz entirely, and
    // id is a random GUID, so it functions as an unguessable capability token
    // rather than an enumerable identifier. See report.tex's Limitations
    // chapter for the full reasoning.
    [HttpGet("{id}")]
    [ProducesResponseType(typeof(OrderResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
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
