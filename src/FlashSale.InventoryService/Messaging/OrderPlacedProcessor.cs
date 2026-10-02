using System;
using System.Text.Json;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.InventoryService.Data;
using FlashSale.InventoryService.Entities;
using FlashSale.InventoryService.Inventory;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace FlashSale.InventoryService.Messaging;

public enum OrderPlacedProcessingOutcome
{
    /// <summary>The Lua reservation ran and a result outbox row was ensured this call.</summary>
    Applied,

    /// <summary>
    /// This exact MessageId was already recorded in the Inbox -- skipped
    /// before even calling Redis. Distinct from reserve.lua's own DUPLICATE
    /// result (Week 7), which is a different idempotency layer keyed on
    /// order id, not MessageId -- see ProcessedMessage.cs's own doc comment.
    /// </summary>
    AlreadyProcessed,
}

/// <summary>
/// The idempotent core of Step 8.1/9.2 for Inventory Service, extracted out
/// of <see cref="OrderPlacedConsumer"/> for the same reason
/// FlashSale.OrderService.Messaging.StockResultProcessor was: testable
/// without a live broker, and it's where the actual correctness logic is.
///
/// "Process, then insert the Inbox row in the same transaction" (Step 9.2)
/// means something slightly different here than on the Order Service side:
/// the true business fact (stock reserved) lives in Redis, which cannot
/// share a Postgres transaction (the same dual-write gap OutboxEvent.cs
/// documents for Week 8). What *can* be atomic is the Postgres-side
/// bookkeeping -- ensuring the result outbox row exists and recording the
/// Inbox row -- and that's what one SaveChangesAsync call here covers.
/// </summary>
public static class OrderPlacedProcessor
{
    public static async Task<OrderPlacedProcessingOutcome> ProcessAsync(
        InventoryServiceDbContext dbContext, InventoryReservationService reservationService,
        OrderPlacedEto orderPlaced, ILogger logger)
    {
        var alreadyProcessed = await dbContext.ProcessedMessages.AnyAsync(m => m.MessageId == orderPlaced.MessageId);
        if (alreadyProcessed)
        {
            return OrderPlacedProcessingOutcome.AlreadyProcessed;
        }

        var result = await reservationService.ReserveAsync(orderPlaced.ProductId, orderPlaced.OrderId.ToString());

        logger.LogInformation(
            "OrderPlaced {OrderId} for product {ProductId} -> {Result}",
            orderPlaced.OrderId, orderPlaced.ProductId, result);

        // DUPLICATE only happens when a *prior* delivery already reserved
        // this order's stock in Redis (reserve.lua's own idempotency check)
        // -- it means "make sure the outbox row exists," not "skip, already
        // handled." See OutboxEvent.cs for the fuller reasoning.
        var eventType = result switch
        {
            ReservationResult.Reserved => "StockReserved",
            ReservationResult.Duplicate => "StockReserved",
            ReservationResult.Rejected => "StockRejected",
            // Sale not open yet (no confirmed warm-up): nothing was reserved, and the
            // order is answered rather than left waiting. Logged above with the result.
            ReservationResult.NotOpen => "StockRejected",
            _ => throw new InvalidOperationException($"Unhandled reservation result: {result}"),
        };

        var outboxRowExists = await dbContext.OutboxEvents.AnyAsync(e => e.OrderId == orderPlaced.OrderId);
        if (!outboxRowExists)
        {
            // MessageId is fresh per outbound event (each service owns its own
            // broker-level idempotency key); CorrelationId is copied through
            // unchanged, which is exactly the distinction Week 11 Step 11.2
            // rests on.
            var payload = eventType == "StockReserved"
                ? JsonSerializer.Serialize(new StockReservedEto
                {
                    OrderId = orderPlaced.OrderId,
                    ProductId = orderPlaced.ProductId,
                    MessageId = Guid.NewGuid(),
                    CorrelationId = orderPlaced.CorrelationId,
                })
                : JsonSerializer.Serialize(new StockRejectedEto
                {
                    OrderId = orderPlaced.OrderId,
                    ProductId = orderPlaced.ProductId,
                    MessageId = Guid.NewGuid(),
                    CorrelationId = orderPlaced.CorrelationId,
                });

            dbContext.OutboxEvents.Add(new OutboxEvent(Guid.NewGuid(), orderPlaced.OrderId, eventType, payload));
        }

        dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), orderPlaced.MessageId, "OrderPlaced"));

        try
        {
            // Plain SaveChangesAsync, not the SaveChangesOnDbContextAsync
            // bypass used in unit tests: this runs inside a full ABP DI scope,
            // where the LazyServiceProvider-backed services AbpDbContext's own
            // SaveChangesAsync needs are actually available.
            await dbContext.SaveChangesAsync();
        }
        catch (DbUpdateException)
        {
            // Lost a race with another delivery of the same order (the unique
            // index on OrderId) and/or the same message (the unique index on
            // MessageId) -- someone else's insert already recorded the same
            // fact(s). Nothing further to do.
        }

        return OrderPlacedProcessingOutcome.Applied;
    }
}
