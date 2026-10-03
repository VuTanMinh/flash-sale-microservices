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
| Order `OrderProcessedConsumer` → `StockResultProcessor` | `OrderProcessed` | the same Order Service Inbox | `Confirmed` → `Completed` + Inbox row | After the commit, or after the message has been requeued for bounded retry (see below) |
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

## An event that arrives before its prerequisite

`OrderProcessed` can reach Order Service before the `StockReserved` that
should have made the order `Confirmed` first: the Process Worker consumes
`StockReserved` in parallel with Order Service, so the completion can win the
race. This is not a conflict and not a duplicate — the two events are simply
out of order — so neither "ack as a no-op" (the completion has not happened
yet) nor "dead-letter" (the completion is still owed) is correct.

`StockResultProcessor` therefore answers with a third outcome,
`ResultProcessingOutcome.NotYetApplicable`: the target state is `Completed`, the
order is still `PendingStock`, so nothing is written — **no Inbox row**, and
the order is left untouched. The consumer does not write an Inbox row for a
message it has not applied, precisely so the retried copy is still processable.

**The requeue is bounded, and it is a separate ladder from the in-process
retry.** The consumer republishes the message onto a delayed retry queue — the
message's `x-order-processed-attempts` header decides which one. Each retry
queue carries its own `x-message-ttl` and dead-letters back to
`flashsale.order.exchange` with routing key `OrderProcessed`, so the copy
returns to the main queue after its delay:

| Attempt | Queue | Wait before the next delivery |
|---|---|---|
| 1 | `OrderProcessed.retry.1` | 2 s |
| 2 | `OrderProcessed.retry.2` | 4 s |
| 3 | `OrderProcessed.retry.3` | 8 s |
| 4 (not requeued) | dead-lettered to `OrderProcessed.dlq` | — |

Those waits are **not** the in-process retry schedule. The two ladders do
different jobs and are allowed to differ:

| Ladder | Waits | Bounds | Used when |
|---|---|---|---|
| `OrderProcessedConsumer.RetryDelays` | 1 s / 2 s / 4 s | a *failing* handler, in-process | a database error or a lost connection while applying the transition |
| `OrderProcessedConsumer.RequeueDelays` | 2 s / 4 s / 8 s | a completion that is *early*, on broker queues | the order is still `PendingStock`, so the transition is not applicable *yet* |

The in-process schedule is 1 s / 2 s / 4 s because that is what every other
consumer and `OutboxPublisherWorker` in this system uses, and what
`docs/outbox.md` documents. The requeue schedule is longer because it waits for
another service to cross the same broker (Inventory's `StockReserved`), not for
a transient local error. Both are bounded.

**Why the requeue publish can be trusted.** Three things, and each was a real
defect before it was there:

- the retry queues are **bound** to the dead-letter exchange with their own
  name as routing key, so the republication is routable at all;
- the publish goes out on a channel created with
  `publisherConfirmationsEnabled` **and** `publisherConfirmationTrackingEnabled`
  (the same pair Order Service's outbox publisher uses), so it returns only
  once the broker has confirmed the message, and **throws** on a return or a
  nack;
- the original is acked **only after** that publish returns.

Without the binding and the confirming channel, the publish returned normally
while the message went nowhere, the original was acked, and the completion was
lost. With them, a requeue that cannot be published throws, and the original is
dead-lettered loudly instead of disappearing.

**What happens if `StockReserved` never arrives.** The retry ladder is finite:
after three requeues (at most 2 s + 4 s + 8 s = 14 s) the message goes to
`OrderProcessed.dlq` and the order stays `PendingStock`. Nothing waits forever,
and the stuck order is visible twice — as a dead letter and to
`ReconciliationWorker`, which re-publishes `OrderPlaced` once the stuck-order
timeout elapses. A duplicate or a late arrival is harmless at every retry: the
Inbox check and the "already in that state" check both run again on each
attempt.

A genuine state *conflict* is unaffected: `StockRejected` for an order that is
already `Confirmed` is still dead-lettered immediately, with nothing recorded,
because it is deterministic rather than early.

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

## Verification (TP-M02, `scripts/verify-delivery-ordering.ps1`)

Where TP-M01 proves one delivery is applied once, this case proves the same
under concurrency, under a *new* `MessageId`, and when the events are out of
order. It runs Order Service first and starts the Process Worker only when the
out-of-order case needs it, so nothing is racing accidentally:

1. **Concurrent duplicates.** The same `StockReserved` is delivered to Order
   Service 8 times at once with the same `MessageId`, and 8 times at once with
   8 different `MessageId`s. The first can only be applied once (one Inbox row
   for that message); the second can only change the state once (`Confirmed`
   exactly once, timestamp stamped exactly once), while every copy is
   accounted for — recorded as a no-op or refused by the unique index. No copy
   is dead-lettered, and the forgeries never touch Redis, so the stock level
   must not move.
2. **Duplicate business event with a new `MessageId`.** The real `OrderPlaced`
   is delivered again, byte for byte, with a fresh `MessageId` — exactly what
   `ReconciliationWorker` does. Redis answers `DUPLICATE`, no second unit is
   deducted, there is no second result Outbox row, and no second stock result
   is published. The same is done for the real `StockReserved` on a
   `Completed` order, which must stay a no-op.
3. **Out-of-order completion.** An `OrderProcessed` for an order still in
   `PendingStock`, published while the Process Worker is stopped. It must land
   in a retry queue within a few seconds, with the DLQ still empty and no
   Inbox row written; once the Worker starts and the order is `Confirmed`, the
   retried message completes the order exactly once. A second order with no
   `StockReserved` at all proves the ladder is bounded: the message is
   dead-lettered after its retries. Finally, a stale `StockReserved` after
   `Completed` must remain a no-op with `CompletedAt` unchanged.

One honest limit: "the same delivery was applied once" is checked by the
observable result (one `Confirmed` transition, stamped once, one Inbox row per
`MessageId`), not by a counter inside the consumer — the consumer has none, and
adding one purely for the test would be test-only state in production code.
