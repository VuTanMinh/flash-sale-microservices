# Delivery Semantics: Inbox, Local Transaction and Ack

RabbitMQ delivers at least once. A message can arrive again after the consumer
has already acted on it, most clearly when the consumer crashes after
committing its work but before acknowledging the message. This document
covers how each consumer keeps the business effect to one, and how
`scripts/verify-delivery.ps1` (test case TP-M01) proves it.

## The rule every consumer follows

1. **Check the Inbox.** If the message's `MessageId` is already recorded,
   acknowledge it and stop.
2. **Do the business step and record the Inbox row in one local transaction**
   (one `SaveChangesAsync`).
3. **Acknowledge only after that commit** (`autoAck: false`).

If the process dies between steps 2 and 3, the broker still holds the message
as unacknowledged. When the connection drops, the broker makes the message
ready again, and the restarted consumer receives it. Step 1 recognises it,
and the business effect is not repeated.

## Consumers

| Consumer | Queue | Inbox | One local transaction | Ack |
|---|---|---|---|---|
| Inventory `OrderPlacedConsumer` → `OrderPlacedProcessor` | `OrderPlaced` | `inventory_service.processed_messages`, unique index on `MessageId` | Result Outbox row (only if none for the `OrderId`) + Inbox row | After the commit |
| Order `StockResultConsumer` → `StockResultProcessor` | `StockReserved`, `StockRejected` | `order_service.processed_messages`, unique index on `MessageId` | Order state change + Inbox row | After the commit |
| Order `OrderProcessedConsumer` → `StockResultProcessor` | `OrderProcessed` | the same Order Service Inbox | `Confirmed` → `Completed` + Inbox row | After the commit |
| Process Worker `StockReservedConsumer` | `ProcessWorker.StockReserved` | none: the Worker has no database | No local state. Its only effect is publishing `OrderProcessed`, with `MessageId` = `OrderId` | After the confirmed publish |

**Inventory has a cross-store step.** The Lua reservation in Redis runs
before the PostgreSQL transaction and cannot be part of it. If the
transaction fails after Redis has reserved, a redelivery gets `DUPLICATE` from
the Lua script, so no second unit is deducted (Week 7, TP-I03). If the crash
comes after the commit, the Inbox stops the redelivery before the Lua script
runs at all.

**Why the Process Worker has no Inbox.** It writes nothing locally, so a
redelivery has nothing local to repeat. It publishes `OrderProcessed` again
with the same `MessageId` (the `OrderId`), and Order Service's Inbox absorbs
the copy. The order is completed once. This is the Worker's equivalent of
the Inbox check, and it is verified the same way.

**Only a unique violation counts as a duplicate.** If two deliveries race
past the Inbox check together, the unique index rejects the second insert
(PostgreSQL 23505). That rejection, and only that one, is treated as "already
processed". Every other database error is retried, then dead-lettered (Week 8,
TP-W03).

## Fault injection for the crash test

The earlier manual crash test (report, Step 9.3) killed Inventory Service
*before* it processed the message. That shows an unprocessed message is
redelivered. It does not show the harder case the roadmap asks for: a crash
*after* the commit and *before* the ack.

To test that case, each consumer calls
`FaultInjection.CrashBeforeAckIfTargeted` between its commit and its ack.
It does nothing unless both settings are given, and neither is set in any
`appsettings.json` file:

| Setting | Meaning |
|---|---|
| `FaultInjection:CrashBeforeAckConsumer` | `OrderPlaced`, `StockResult`, `OrderProcessed` or `ProcessWorker` |
| `FaultInjection:CrashBeforeAckCorrelationId` | Only a message with this `CorrelationId` triggers the crash |

When both match, the consumer logs a warning, flushes its log, and kills its
own process (`Process.Kill`). This is an abrupt end with no graceful shutdown,
so nothing can ack on the way out. Targeting one correlation id means other
messages in the queue are unaffected. The test client sets that id with the
`X-Correlation-Id` header.

## Verification (TP-M01, `scripts/verify-delivery.ps1`)

**Inbox uniqueness:**

- Both Inbox tables have a unique index on `MessageId`.
- Inserting the same `MessageId` twice as the service's own database account
  fails with 23505.

**Local transaction:**

- With INSERT on the Inbox table revoked, a consumer's business write is
  rolled back with it. For Inventory, that means no result Outbox row; for
  Order Service, the order stays `PendingStock`.
- The message is retried, then dead-lettered.
- After the privilege is restored, replaying the dead letter applies it once.

**Crash after commit, before ack, for each of the four consumers:**

1. Start the service with the crash target set.
2. Place an order with the target correlation id.
3. Check that the process exited, the work was committed, and the message is
   still in the queue.
4. Restart the service without the target.
5. Check that the same `MessageId` was delivered again and treated as already
   processed (for the Worker: published again and absorbed by Order Service).
6. Check that the order still reaches `Completed` with:
   - exactly one Redis deduction;
   - one Inbox row per message;
   - unchanged decision and completion timestamps.

At the end, every queue and DLQ is empty.
