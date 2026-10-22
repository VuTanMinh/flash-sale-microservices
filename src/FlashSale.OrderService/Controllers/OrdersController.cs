using System;
using System.Threading.Tasks;
using FlashSale.OrderService.Data;
using FlashSale.OrderService.Entities;
using FlashSale.OrderService.Messaging;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using Npgsql;
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
    private readonly IOptions<AdmissionOptions> _admissionOptions;
    private readonly OrderAdmissionGate _admissionGate;
    private readonly OutboxBacklogMonitor _backlogMonitor;
    private readonly IConfiguration _configuration;

    public OrdersController(
        OrderServiceDbContext dbContext,
        ICorrelationIdProvider correlationIdProvider,
        IOptions<AdmissionOptions> admissionOptions,
        OrderAdmissionGate admissionGate,
        OutboxBacklogMonitor backlogMonitor,
        IConfiguration configuration)
    {
        _dbContext = dbContext;
        _correlationIdProvider = correlationIdProvider;
        _admissionOptions = admissionOptions;
        _admissionGate = admissionGate;
        _backlogMonitor = backlogMonitor;
        _configuration = configuration;
    }

    public record CreateOrderRequest(string ProductId, int Quantity);

    public record OrderHistoryItem(string? From, string To, DateTime At, bool Implied);

    public record OrderResponse(
        Guid Id,
        string ProductId,
        int Quantity,
        string State,
        DateTime RequestAcceptedAt,
        DateTime? ConfirmedOrRejectedAt,
        DateTime? CompletedAt,
        IReadOnlyList<OrderHistoryItem> History);

    // Documented outcomes (exported to docs/api-contract-v1.json; behaviour
    // specified in docs/order-api.md): 201 new order, 200 replay of the same
    // Idempotency-Key + payload, 400 missing key or invalid body, 409 key
    // reused with a different payload.
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

        // docs/order-api.md: validated before any database write, so a
        // rejected request leaves no order and no Outbox row behind.
        if (string.IsNullOrWhiteSpace(request.ProductId))
        {
            return BadRequest("productId is required.");
        }

        // Single-unit flash-sale orders: reserve.lua decrements exactly one
        // unit per order, so any other quantity would be accepted here but
        // reserved as one downstream.
        if (request.Quantity != 1)
        {
            return BadRequest("quantity must be 1.");
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

            return Ok(await ToResponseAsync(existing));
        }

        // Week 12 box 1 (C3 admission): the idempotency lookup above runs
        // first, so a retry of an already-accepted order is answered from the
        // existing row (200 or 409) without ever touching the gate. Only a
        // brand-new order is admitted through the gate -- after the lookup and
        // before any database write -- so a refused request (503) leaves no
        // order and no Outbox row behind.
        //
        // Week 12 box 2 adds the backlog bound before the concurrency gate:
        // when the Outbox already holds MaxOutboxBacklog unpublished rows, a
        // new order is refused (503, reason="backlog") instead of growing the
        // backlog without limit. The count is read from OutboxBacklogMonitor,
        // not a per-request count(*): it is the worker's last measured count
        // plus the orders this process has accepted since (see
        // docs/load-shedding.md for the order of checks and the soft-bound
        // caveat). Before the first poll the monitor reads 0, so an unknown
        // backlog is admitted (the concurrency gate still applies).
        var gateHeld = false;
        if (_admissionOptions.Value.Enabled)
        {
            var maxBacklog = _admissionOptions.Value.MaxOutboxBacklog;
            if (maxBacklog > 0 && _backlogMonitor.Unpublished >= maxBacklog)
            {
                OrderMetrics.AdmissionRejected.WithLabels("backlog").Inc();
                Response.Headers["Retry-After"] = "1";
                return StatusCode(StatusCodes.Status503ServiceUnavailable,
                    "The order backlog is at its limit; retry shortly.");
            }

            if (!_admissionGate.TryEnter())
            {
                OrderMetrics.AdmissionRejected.WithLabels("concurrency").Inc();
                Response.Headers["Retry-After"] = "1";
                return StatusCode(StatusCodes.Status503ServiceUnavailable,
                    "The service is at its admission limit for new orders; retry shortly.");
            }

            gateHeld = true;
        }

        try
        {
            // Test-only fault injection (same pattern as CrashBeforeAck*): when
            // set, holds the slot for that long so a test can saturate the gate
            // deterministically. Off by default and never in any appsettings file.
            // Inside the try so a cancellation during the delay still releases
            // the slot in the finally below.
            if (gateHeld)
            {
                var holdMs = _configuration["FaultInjection:AdmissionHoldMilliseconds"];
                if (int.TryParse(holdMs, out var hold) && hold > 0)
                {
                    await Task.Delay(hold);
                }
            }

            var order = new Order(Guid.NewGuid(), idempotencyKey, request.ProductId, request.Quantity, correlationId);
            _dbContext.Orders.Add(order);
            // Same SaveChangesAsync call as the order insert above -- this single
            // fact is the entire point of the Outbox pattern (checklist Step 6.1).
            // Two separate SaveChanges calls here would reintroduce the exact
            // dual-write problem Outbox exists to eliminate: either the order or
            // the "an event needs publishing" fact could commit without the other.
            _dbContext.OutboxEvents.Add(OutboxEvent.ForOrderPlaced(order));
            // Week 11 box 2: the creation history row (FromState = null) is written
            // in this same transaction, so the history can never lag the order.
            _dbContext.OrderStatusHistory.Add(new OrderStatusHistory(
                Guid.NewGuid(), order.Id, null, OrderState.PendingStock, null, order.RequestAcceptedAt, false));
            try
            {
                await _dbContext.SaveChangesAsync();
            }
            catch (DbUpdateException ex) when (ex.InnerException is PostgresException
            {
                SqlState: PostgresErrorCodes.UniqueViolation, ConstraintName: "IX_orders_IdempotencyKey"
            })
            {
                // Lost a race: a concurrent request with the same key committed
                // between our lookup and our insert. Its order is the one the key
                // belongs to, so answer exactly as a replay (or a conflict) would,
                // instead of a 500. Only this specific unique violation is treated
                // this way; any other database error still propagates.
                _dbContext.ChangeTracker.Clear();
                var winner = await _dbContext.Orders.AsNoTracking()
                    .FirstAsync(o => o.IdempotencyKey == idempotencyKey);
                if (winner.ProductId != request.ProductId || winner.Quantity != request.Quantity)
                {
                    return Conflict("This Idempotency-Key was already used with a different request.");
                }

                return Ok(await ToResponseAsync(winner));
            }

            // Counted only after the commit, not before: an order that failed to
            // persist was never accepted, and Week 13/14 compare this counter
            // against JMeter's own request count to detect exactly that kind of
            // divergence.
            OrderMetrics.OrdersAccepted.Inc();

            // Week 12 box 2: tell the backlog monitor that a NEW order (and its
            // Outbox row) is now durable, so the admission gate reflects it
            // immediately instead of waiting for the next Outbox poll. Deliberately
            // not called on the idempotent replay or the unique-violation race
            // paths above (those return an existing order and write nothing).
            _backlogMonitor.RecordAccepted();

            return StatusCode(201, await ToResponseAsync(order));
        }
        finally
        {
            // Release the slot on every exit path -- 201, the unique-violation
            // race (200/409), or an exception -- so a refused or failed request
            // can never leak a slot.
            if (gateHeld)
            {
                _admissionGate.Release();
            }
        }
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

        return Ok(await ToResponseAsync(order));
    }

    // Timestamps are stored as UTC in a "timestamp without time zone" column
    // and come back with Kind = Unspecified; marking them UTC keeps the "Z"
    // suffix, so a replayed order serialises exactly like the original.
    private async Task<OrderResponse> ToResponseAsync(Order order)
    {
        // Week 11 box 2: expose the status history read-only, ordered by the
        // database-assigned insertion-order key Seq (review R1). Ordering by At
        // then Id is wrong: At can arrive out of order (the Worker can start
        // before Order Service records Confirmed) and Id is a random Guid.
        var rows = await _dbContext.OrderStatusHistory
            .Where(h => h.OrderId == order.Id)
            .OrderBy(h => h.Seq)
            .ToListAsync();

        var history = rows
            .Select(h => new OrderHistoryItem(
                h.FromState.HasValue ? h.FromState.Value.ToString() : null,
                h.ToState.ToString(),
                AsUtc(h.At),
                h.Implied))
            .ToList();

        return new OrderResponse(
            order.Id,
            order.ProductId,
            order.Quantity,
            order.State.ToString(),
            AsUtc(order.RequestAcceptedAt),
            order.ConfirmedOrRejectedAt is { } decidedAt ? AsUtc(decidedAt) : null,
            order.CompletedAt is { } completedAt ? AsUtc(completedAt) : null,
            history);
    }

    private static DateTime AsUtc(DateTime value) => DateTime.SpecifyKind(value, DateTimeKind.Utc);
}
