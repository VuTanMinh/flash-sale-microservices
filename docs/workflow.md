# Main Workflow: Placing an Order

This is the one business workflow in the system, described from the code on
branch `week1-2` (Week 8). The step numbers match the numbered arrows in the
happy-path diagram in `docs/sequence-diagrams.md`. `scripts/verify-workflow.ps1`
checks this description against the code and against real orders traced
through all three services (test case TP-W04).

## Overview

An order is accepted when a row is committed, not when stock is reserved. The
client gets `201 Created` with state `PendingStock`, and the rest of the
workflow runs asynchronously:

1. Order Service writes the order and its `OrderPlaced` event in one
   transaction (Transactional Outbox).
2. A background publisher sends `OrderPlaced`. A row is marked published only
   after RabbitMQ confirms that the message reached every required queue.
3. Inventory Service reserves one unit in Redis with one atomic Lua script.
   It then records the result in its own Outbox, in one transaction with its
   Inbox row.
4. Inventory Service's publisher sends `StockReserved` or `StockRejected`.
5. Order Service applies the result: `PendingStock` becomes `Confirmed` or
   `Rejected`.
6. For a reserved order, the Process Worker waits a fixed delay and publishes
   `OrderProcessed`. Order Service then moves the order from `Confirmed` to
   `Completed`.
7. The client polls `GET /api/orders/{id}` to see the state.

Every consumer acknowledges a message only after its database transaction
commits. Every consumer checks its Inbox (`processed_messages`, unique
`MessageId`) before doing anything, so a redelivered message changes nothing.

## Steps

| Steps | What happens | Code | If it fails | Test case |
|---|---|---|---|---|
| 1–4 | Validate (key present, non-blank `productId`, `quantity` = 1). Look up the `Idempotency-Key`. Insert the order (`PendingStock`) and its `OrderPlaced` Outbox row with one `SaveChangesAsync`, then answer `201`. | `OrdersController.CreateOrderAsync` | Invalid body: `400`, nothing written. Same key and payload: `200` with the original order. Same key, other payload: `409`. Losing a concurrent race on the key: answered as a replay. Outbox insert refused: the whole request fails and no order exists. | TP-A01–A07, TP-O01 |
| 5–9 | Every 2 s, read up to 50 unpublished rows, oldest first. Check that queue `OrderPlaced` exists and is bound. Publish with `mandatory` and wait for the confirm. Mark the row published. | Order `OutboxPublisherWorker`, `RabbitMqOutboxPublisher` | Missing queue or binding, negative confirm, returned message or lost connection: not published. Retried after 1, 2 and 4 s, then left for the next poll. The `MessageId` stays the same. | TP-O01, TP-O02 |
| 10–15 | Inventory Service checks its Inbox, then runs `reserve.lua` on `inventory:{p}`, `processed:{p}` and `sale:open:{p}`. `RESERVED` and `DUPLICATE` map to `StockReserved`. `REJECTED` and `NOT_OPEN` map to `StockRejected`. One transaction writes the Outbox row (only if none exists for this `OrderId`) and the Inbox row. Then ack. | `OrderPlacedConsumer`, `OrderPlacedProcessor`, `InventoryReservationService`, `Redis/reserve.lua` | Database error after the Lua script: retried, then dead-lettered. A replay gets `DUPLICATE`, so there is no second deduction. Only a unique violation counts as a duplicate. | TP-I01–I03 |
| 16–20 | Every 2 s, Inventory's publisher reads unpublished rows. `StockReserved` requires both `StockReserved` and `ProcessWorker.StockReserved`. `StockRejected` requires `StockRejected`. Publish with `mandatory` and confirm, then mark published. | Inventory `OutboxPublisherWorker`, `RabbitMqOutboxPublisher` | Same as steps 5–9. | TP-O02 |
| 21–23 | Order Service checks its Inbox. One transaction applies `PendingStock` → `Confirmed` (or `Rejected`) and inserts the Inbox row. Then ack. A result for a state the order already has, or has moved past, is a no-op. | `StockResultConsumer`, `StockResultProcessor` | Database error: retried after 1, 2 and 4 s, then dead-lettered; replay applies it. Conflicting result (for example `StockReserved` for a `Rejected` order): dead-lettered at once. Unknown order: acked. | TP-W01, TP-W03 |
| 24–27 | The Process Worker receives its own copy of `StockReserved`. It waits a fixed 200 ms, checks queue `OrderProcessed`, publishes `OrderProcessed` with `MessageId` = `OrderId`, and acks. It has no database and no Inbox. | `StockReservedConsumer`, `OrderProcessedPublisher` | Publish failure: retried, then dead-lettered to `ProcessWorker.StockReserved.dlq`. A redelivery publishes the same `MessageId` again, and Order Service's Inbox absorbs it. | TP-P01 (Week 11) |
| 28–30 | Order Service checks its Inbox, then applies `Confirmed` → `Completed` and the Inbox row in one transaction. Then ack. | `OrderProcessedConsumer`, reusing `StockResultProcessor` | Same retry and DLQ as steps 21–23. **Known gap:** if this arrives while the order is still `PendingStock`, the transition is illegal and the message is dead-lettered instead of retried (Weeks 9 and 11). | TP-W04 (live order), TP-M02 |
| 31–32 | `GET /api/orders/{id}` returns the current state and its timestamps. An unknown id returns `404`. | `OrdersController.GetOrderAsync` | — | TP-A01 |

**Rejection path.** The steps are the same until the Lua script. `REJECTED`
(the sale is open and the stock is 0) and `NOT_OPEN` (no confirmed warm-up)
both deduct nothing and produce `StockRejected`. Only Order Service subscribes
to `StockRejected`, so the order ends as `Rejected` and never reaches the
Process Worker.

**Safety net.** `ReconciliationWorker` checks every 30 s for orders that
have been `PendingStock` for more than 30 s, and writes a new `OrderPlaced`
Outbox row for each one with a new `MessageId`. Because every step above is
idempotent, this cannot deduct twice. It is verified in Week 10 (TP-F02).

## Timestamps along the path

These columns record the path and are used by `scripts/verify-workflow.ps1`.
All of them are UTC, written by processes on the same host.

| Step | Column |
|---|---|
| 3 | `order_service.orders.RequestAcceptedAt`, `order_service.outbox_events.CreatedAt` |
| 9 | `order_service.outbox_events.PublishedAt` |
| 14 | `inventory_service.outbox_events.CreatedAt`, `inventory_service.processed_messages.ProcessedAt` |
| 20 | `inventory_service.outbox_events.PublishedAt` |
| 22 | `order_service.orders.ConfirmedOrRejectedAt`, `order_service.processed_messages.ProcessedAt` |
| 29 | `order_service.orders.CompletedAt`, `order_service.processed_messages.ProcessedAt` (`MessageId` = `OrderId`) |

A publisher stamps `PublishedAt` after the confirm returns, so the consumer
may already have committed before `PublishedAt` is written. The verifier
therefore only checks orderings that cause and effect guarantee. For example,
Inventory's Inbox row can only exist after the Order Outbox row was
committed.

The Week 11 trace (TP-P03) adds the stage timestamps and the
`CorrelationId` reconstruction from all three services' logs.
