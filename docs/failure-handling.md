# Failure handling: retries, poison messages and the service DLQ (Week 10)

`scripts/verify-failures.ps1` (test case TP-F01) proves that each consumer's
retry is bounded, that a message that fails for good lands in the **correct
service's** dead-letter queue, and that an exhausted message can be replayed
after the fix. This document records the classification and limits the code
implements, and the procedure for inspecting and replaying a dead letter.

## Classify before retrying

Chapter 9 of the study guide: classify a failure before retrying it. Transient
(a brief dependency outage) is retried; permanent (an invalid message) is not;
a business rejection is a decision, not a retry. Each of the four consumers
does exactly that before doing any work:

| Class | What it is | Consumer action |
|---|---|---|
| **Transient** | A short-lived fault in a dependency (a database outage, a missing required queue) | Retry in-process with backoff, then dead-letter after the attempt limit |
| **Permanent (poison)** | A message that deserializes but has an empty `MessageId` / `OrderId` / `ProductId`, or one that does not deserialize at all | No retry: `nack(requeue:false)` straight to the service DLQ, with no Inbox row and no Redis/database/state effect |
| **Business rejection** | A genuine state conflict, e.g. `StockRejected` after the order is already `Confirmed` (`InvalidOrderStateTransitionException`) | No retry: `nack(requeue:false)` straight to the service DLQ (`StockResultConsumer`, `OrderProcessedConsumer`) |

## Validation: a permanent message is never processed

Before this week, a message that *deserialized* but had an empty identity field
was processed as if it were real. For example, an `OrderPlaced` with an empty
`MessageId`, `OrderId` or `ProductId` made Inventory Service run `reserve.lua`
with empty keys and write a `StockRejected` for order `00000000-…`, and a
**second, different** invalid message with an empty `MessageId` was then wrongly
skipped as "already processed" because the Inbox had recorded `Guid.Empty`.
That is a duplicate-identity bug, not just a validation gap.

Each consumer now checks the identity fields immediately after deserialization
and before any Redis/SQL/Inbox work:

| Consumer | Fields required valid | Invalid-message log |
|---|---|---|
| Inventory `OrderPlacedConsumer` | `MessageId`, `OrderId`, `ProductId` non-empty; `Quantity` = 1 | `Invalid OrderPlaced message: {Field} is empty; routing to DLQ` / `Invalid OrderPlaced message: Quantity must be 1; routing to DLQ` |
| Order `StockResultConsumer` | `MessageId`, `OrderId`, `ProductId` non-empty | `Invalid {StockReserved\|StockRejected} message: {Field} is empty; routing to DLQ` |
| Order `OrderProcessedConsumer` | `MessageId`, `OrderId` non-empty | `Invalid OrderProcessed message: {Field} is empty; routing to DLQ` |
| Worker `StockReservedConsumer` | `MessageId`, `OrderId`, `ProductId` non-empty | `Invalid StockReserved message: {Field} is empty; routing to DLQ` |

`OrderProcessed` is the one event with no `ProductId` (the order already knows
its product), so only its two identity fields are checked. `OrderPlaced` is the
one event with a `Quantity`: the reservation scope is exactly one unit and the
API already rejects other quantities, so Inventory's `OrderPlacedConsumer`
treats `Quantity != 1` as permanent too — the same immediate
`nack(requeue:false)` with no Lua call, no Redis change and no rows. An invalid
message is nacked with `requeue:false` at once — no retry, no Inbox row, no
Redis or database effect, no state change — and dead-letters to that service's
DLQ.

## Bounded transient retry

Every consumer carries the same in-process ladder (also used by
`OutboxPublisherWorker`, Week 6):

| Attempt | Wait before the next attempt |
|---|---|
| 1 (initial) | — |
| 2 | 1 s |
| 3 | 2 s |
| 4 (final) | 4 s, then dead-letter |

In code: `RetryDelays = [1 s, 2 s, 4 s]`, `MaxAttempts = 4` in
`OrderPlacedConsumer`, `StockResultConsumer`, `OrderProcessedConsumer` and the
Process Worker's `StockReservedConsumer`. After the fourth attempt the message
is dead-lettered with its original body intact (enough to diagnose it), not
requeued forever. Only a PostgreSQL unique violation (23505) is treated as "a
concurrent duplicate already recorded this" — every other database error is
retried then dead-lettered (`docs/design-decisions.md` §4).

The in-process ladder is distinct from `OrderProcessedConsumer`'s *requeue*
ladder (2 s / 4 s / 8 s on `OrderProcessed.retry.*` queues), which handles a
completion that arrives before its `StockReserved` — a different mechanism for a
different job, both bounded (`docs/delivery-semantics.md`).

## DLQ per service

Each main queue dead-letters into `flashsale.dlx` and, from there, into exactly
one service's DLQ:

| Consumer | Main queue | DLQ | Routing into the DLQ |
|---|---|---|---|
| Inventory `OrderPlacedConsumer` | `OrderPlaced` | `OrderPlaced.dlq` | main queue `x-dead-letter-exchange=flashsale.dlx`; original key `OrderPlaced` preserved |
| Order `StockResultConsumer` | `StockReserved` / `StockRejected` | `StockReserved.dlq` / `StockRejected.dlq` | `x-dead-letter-exchange=flashsale.dlx`; original key preserved |
| Order `OrderProcessedConsumer` | `OrderProcessed` | `OrderProcessed.dlq` | `x-dead-letter-exchange=flashsale.dlx`; original key `OrderProcessed` preserved |
| Worker `StockReservedConsumer` | `ProcessWorker.StockReserved` | `ProcessWorker.StockReserved.dlq` | `x-dead-letter-exchange=flashsale.dlx` **and** `x-dead-letter-routing-key=ProcessWorker.StockReserved` |

The Worker's main queue is the one that sets `x-dead-letter-routing-key`:
`flashsale.dlx` is a direct exchange shared by all three services, and without
the rewritten key a Worker dead letter (original key `StockReserved`) would also
be copied into Order Service's `StockReserved.dlq`, which is bound to the same
exchange with that key. The rewrite keeps the two dead-letter streams separate,
so each DLQ contains only that service's own failures (isolation).

## Replay after the fix

A DLQ does not repair anything — it needs an owner and a deliberate resolution
path. The procedure is:

1. Inspect the dead letter (management UI, or
   `GET /api/queues/%2F/<dlq>/get`); its `x-death` header names the source queue
   and the reason (`rejected` for an exhausted retry or a nacked poison message).
2. Fix the root cause (restore the revoked grant, recreate the missing queue,
   correct the upstream producer).
3. Republish the message **unchanged** — same body, so the same `MessageId`.
4. The consumer applies it exactly once: the Inbox check recognises a replay of
   an already-applied message as a no-op, and Inventory's `reserve.lua` answers
   `DUPLICATE` for an order already reserved, so an exhausted `OrderPlaced` that
   reserved stock before its database write failed is completed without a second
   deduction.

The event id stays stable on republish (`docs/design-decisions.md` §1); a
delivery tag is never used as a deduplication key.

## Verification (TP-F01, `scripts/verify-failures.ps1`)

For each of the four consumers the verifier shows:

- **Transient** — a fault fixed inside the retry window (a revoked Inbox
  `INSERT` restored after ~2 s; for the Worker, a missing required
  `OrderProcessed` queue that is recreated). The message is applied once,
  nothing is dead-lettered, and the log shows retries.
- **Exhausted** — a fault that outlasts the ladder. Exactly 4 attempts are
  logged with about 1 s / 2 s / 4 s gaps (read from the log timestamps), the
  message lands in **that service's** DLQ with `x-death` naming the source queue
  and reason `rejected`, the main queue is empty (no loop), and every other DLQ
  is unchanged (isolation).
- **Poison** — malformed JSON, and a well-formed message with an empty
  `MessageId`, each dead-lettered after **one** attempt with no retry log lines,
  no Inbox row and no Redis or state change; two different empty-`MessageId`
  messages **both** reach the DLQ.
- **Replay** — the exhausted message is republished unchanged and applied once.

`docs/test-plan.md` holds the case row (TP-F01); `scripts/verify-failures.ps1`
prints `PASS`/`FAIL` per check and exits non-zero on any failure.
