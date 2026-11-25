using System;
using System.Text.Json;
using System.Threading.Tasks;
using FlashSale.EventContracts;
using FlashSale.InventoryService.Data;
using FlashSale.InventoryService.Entities;
using FlashSale.InventoryService.Inventory;
using Microsoft.EntityFrameworkCore;
using Npgsql;
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
    /// <summary>Production entry point — always saves via the real, DI-backed SaveChangesAsync.</summary>
    public static Task<OrderPlacedProcessingOutcome> ProcessAsync(
        InventoryServiceDbContext dbContext, InventoryReservationService reservationService,
        OrderPlacedEto orderPlaced, ILogger logger, Action? afterReserve = null) =>
        ProcessAsync(dbContext, reservationService, orderPlaced, logger,
            () => dbContext.SaveChangesAsync(), afterReserve);

    /// <summary>
    /// Same logic, with the save call injectable. Exists only so a test can
    /// substitute AbpDbContext's SaveChangesOnDbContextAsync bypass for the real
    /// SaveChangesAsync (see FlashSale.OrderService.Tests.OutboxAtomicityTests for
    /// the same documented limitation). Production code (the overload above)
    /// always uses the real one.
    /// </summary>
    public static async Task<OrderPlacedProcessingOutcome> ProcessAsync(
        InventoryServiceDbContext dbContext, InventoryReservationService reservationService,
        OrderPlacedEto orderPlaced, ILogger logger, Func<Task<int>> saveChangesAsync, Action? afterReserve = null)
    {
        var alreadyProcessed = await dbContext.ProcessedMessages.AnyAsync(m => m.MessageId == orderPlaced.MessageId);
        if (alreadyProcessed)
        {
            return OrderPlacedProcessingOutcome.AlreadyProcessed;
        }

        // Look the stored result up BEFORE reserving (Week 14 undersell gap):
        // an order rejected with NOT_OPEN before warm-up whose OrderPlaced is
        // re-triggered after the sale opens must not take a unit in Redis while
        // its stored result stays StockRejected. When a result row already
        // exists, we must not call ReserveAsync at all.
        var existingResult = await dbContext.OutboxEvents.FirstOrDefaultAsync(e => e.OrderId == orderPlaced.OrderId);

        // Metric decision label (Week 11, TP-P04), computed in the branch below:
        // the fresh-reservation path sets reserved/rejected/not_open, the
        // stored-result path sets duplicate (no reservation ran).
        string decision;

        if (existingResult is null)
        {
            var result = await reservationService.ReserveAsync(orderPlaced.ProductId, orderPlaced.OrderId.ToString());

            logger.LogInformation(
                "OrderPlaced {OrderId} for product {ProductId} -> {Result}",
                orderPlaced.OrderId, orderPlaced.ProductId, result);

            // The crash test's hook between the Redis decision and the save below
            // (FaultInjection.CrashAfterReserveIfTargeted); null outside the consumer.
            afterReserve?.Invoke();

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

            // The label is the business outcome, not the raw Lua answer: a
            // DUPLICATE here still counts as reserved (an earlier attempt
            // reserved before its save failed).
            decision = result switch
            {
                ReservationResult.Rejected => "rejected",
                ReservationResult.NotOpen => "not_open",
                _ => "reserved",
            };
        }
        else
        {
            // A stored result already exists for this order, so no reservation
            // ran at all this call: this delivery is a duplicate of a prior
            // business decision, whatever that decision was.
            decision = "duplicate";

            if (existingResult.Published)
            {
                // Week 10 box 2: a result was already published for this order, but
                // the downstream copy was lost before Order Service applied it (most
                // likely dead-lettered and purged) -- that is the only reason a
                // re-triggered OrderPlaced reaches here with a result row already
                // Published. Re-send that same stored result (same payload, same
                // MessageId) instead of writing a new row or running a second
                // deduction: no reservation ran at all this call, so no extra unit
                // was taken. Order Service's Inbox absorbs the copy if it was
                // somehow already applied, so the re-send is idempotent.
                existingResult.MarkForRepublish();
                logger.LogWarning(
                    "OrderPlaced {OrderId}: stored result {EventType} is already published; re-queuing it for re-publication",
                    orderPlaced.OrderId, existingResult.EventType);
            }
            // else: a stored result that exists but is not yet published is
            // left for the outbox publisher: no reservation ran and no new row
            // is written here.
        }

        dbContext.ProcessedMessages.Add(new ProcessedMessage(Guid.NewGuid(), orderPlaced.MessageId, "OrderPlaced"));

        try
        {
            // The production overload passes the real, DI-backed SaveChangesAsync
            // (AbpDbContext's SaveChangesAsync needs the LazyServiceProvider from
            // the ABP DI container); a test passes SaveChangesOnDbContextAsync
            // instead, since a directly-constructed DbContext has no container.
            await saveChangesAsync();

            // Week 11 (TP-P04): one committed business decision per call,
            // recorded only after the commit succeeded. The label was computed
            // in the branch above: reserved / rejected / not_open for a fresh
            // reservation, duplicate for a stored-result branch (no reservation
            // ran).
            InventoryMetrics.StockDecisions.WithLabels(decision).Inc();
        }
        catch (DbUpdateException ex) when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        {
            // Lost a race with another delivery of the same order (the unique
            // index on OrderId) and/or the same message (the unique index on
            // MessageId) -- someone else's insert already recorded the same
            // fact(s). Nothing further to do.
            //
            // ONLY a unique violation means that. Any other database error
            // (connection lost, permission, ...) must propagate so the message
            // is retried and finally dead-lettered rather than acked. In the
            // fresh-reservation branch Redis has already reserved the unit, and
            // acking here would lose the StockReserved result for good
            // (docs/design-decisions.md §4); a retry reaches reserve.lua again,
            // gets DUPLICATE, and writes the missing result without a second
            // deduction.
        }

        return OrderPlacedProcessingOutcome.Applied;
    }
}
