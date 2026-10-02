# Design decisions: idempotency, ordering/replay, schema ownership, Redis/PostgreSQL boundary (Week 4)

Each section gives the **definition** the project adopts, the **mechanism in code** (cited as `file` + `symbol`, checked by `scripts/verify-design-decisions.ps1`), and the **known gaps** with the roadmap box that closes them. Requirements: `docs/teacher-brief.md` §2b, §5 ("Idempotent Consumer", "Duplicate hoặc invalid event không được tạo state transition lặp").

## 1. Transport versus business idempotency

| Layer | What it dedupes | Key | Mechanism in code |
|---|---|---|---|
| **Client transport** | A client resending the same HTTP request (timeouts, retries) | `Idempotency-Key` header | `OrdersController.CreateOrderAsync` looks up `Order.IdempotencyKey`, enforced by a unique index (`OrderServiceDbContext`: `HasIndex(x => x.IdempotencyKey).IsUnique()`). Same key + same payload returns the original order (200). Same key + different payload returns 409. |
| **Broker transport** | RabbitMQ redelivering the same message (at-least-once) | `MessageId` | Each consumer keeps its own Inbox (`ProcessedMessage`, unique `MessageId`) and writes it in the same `SaveChangesAsync` as the business change: `StockResultProcessor.ProcessAsync` (Order Service), `OrderPlacedProcessor.ProcessAsync` (Inventory Service). |
| **Business** | The same business fact arriving as a *different* message (new `MessageId`), e.g. the reconciliation job re-publishing `OrderPlaced` for a stuck order | `OrderId` | Redis: `reserve.lua` keeps `processed:{productId}` and returns `DUPLICATE` for an order already reserved, so stock is never deducted twice. Inventory Outbox: unique `OrderId` (`InventoryServiceDbContext`), so at most one result event exists per order. Order Service: the guarded state machine (`Order.TransitionTo`) refuses repeated or illegal transitions. Process Worker: `MessageId = OrderId` on `OrderProcessedEto` (`StockReservedConsumer` in the Process Worker), so a replay produces an identical message that Order Service's Inbox drops. |

**Rule:** transport keys (`Idempotency-Key`, `MessageId`) are never used as business keys, and vice versa. A new `MessageId` for the same `OrderId` must still produce exactly one stock deduction and one applied result.

## 2. Event ordering and replay

RabbitMQ gives no ordering guarantee across queues, and redelivery can reorder messages within a queue. The design therefore **does not rely on order**. Every consumer must reach the same final state for any arrival order and any number of duplicates:

| Situation | Defined behaviour |
|---|---|
| Duplicate of an applied message (same `MessageId`) | Inbox hit, so ack as a no-op (`ResultProcessingOutcome.AlreadyProcessed`). |
| Result event for an order already in that state, or already past it on `PendingStock → Confirmed → Completed` (different `MessageId`, e.g. `StockReserved` after `Completed`) | Ack as a no-op and record the Inbox row (`StockResultProcessor`: `IsAtOrPast`). Before 2026-10-01 a stale event like this was dead-lettered; fixed in Week 5. |
| Result that conflicts with the current state (e.g. `StockRejected` after `Confirmed`) | Deterministic conflict: no retry, nack to the service's DLQ (`InvalidOrderStateTransitionException`). |
| Downstream event arriving **before** its prerequisite (e.g. `OrderProcessed` while the order is still `PendingStock`) | **Defined:** temporary, so nack with bounded retry (requeue), never dropped. Under the six-state model, an early `OrderProcessed` while `Confirmed` applies `Confirmed → Processing → Completed` with an implied history row (`docs/order-state-machine.md`). |
| Stale event for an earlier state (e.g. `OrderProcessingStarted` after `Completed`, Week 11) | Ack as a no-op. |

**Replay:** replaying any message any number of times must leave stock, order state and Outbox rows unchanged after the first application. The prototype in `docs/order-state-machine.md` checked 150 reordered/duplicated sequences against these rules.

**Known gap (code violates the definition):** `OrderProcessedConsumer` sends an `OrderProcessed` that arrives while the order is still `PendingStock` straight to the DLQ (it treats `InvalidOrderStateTransitionException` as deterministic). The Process Worker consumes `StockReserved` in parallel with Order Service, so under backlog this can happen: the order would then stay `Confirmed` and never reach `Completed`. **Closed by:** Week 9, "late/out-of-order completion", and the Week 11 Processing work.

## 3. Schema ownership

| Schema | Owner account | Who may read/write | Contents |
|---|---|---|---|
| `order_service` | `order_service_user` | Order Service only | `orders`, `outbox_events`, `processed_messages`, C0/C1 `inventory` and `baseline_orders` |
| `inventory_service` | `inventory_service_user` | Inventory Service only | `outbox_events`, `processed_messages`, its migration history |
| `public` | `order_service_user` | Order Service only | ABP module tables and Order Service's migration history |
| Redis `inventory:*`, `processed:*` | Inventory Service | Inventory Service (and the warm-up script) | available stock, reserved order ids |

No service reads another service's schema; cross-service facts travel only as events. This is enforced by grants (`infra/initdb/01-create-service-roles.sql`) and checked by `scripts/verify-environment.ps1`, which runs 7 isolation checks: each account can use its own schema and is denied the other's. Details: `docs/erd.md`, `docs/infrastructure.md`.

## 4. Redis/PostgreSQL failure boundary (Inventory Service)

Reserving stock touches two stores that cannot share a transaction: Redis (the stock decision) and PostgreSQL (the Inbox row and the Outbox result event). The boundary is defined so that **Redis is the source of truth for the reservation decision, and PostgreSQL records the outcome**:

1. `OrderPlacedProcessor.ProcessAsync` checks the Inbox. On a hit, ack.
2. `reserve.lua` runs atomically in Redis: `RESERVED`, `REJECTED` or `DUPLICATE`.
3. In **one** PostgreSQL transaction, it writes the Outbox result (if no row exists for this `OrderId`) and the Inbox row.
4. Only after that commit is the message acked.

| Failure point | Defined outcome |
|---|---|
| Crash or PostgreSQL error **before** step 2 | Nothing changed; the redelivered message is processed normally. |
| PostgreSQL fails **after** Redis reserved (between steps 2 and 3) | Not acked, so it is redelivered. `reserve.lua` returns `DUPLICATE` (no second deduction), which is treated as `StockReserved`, and step 3 writes the missing Outbox row. Exactly one deduction and one result. |
| Crash after step 3, before the ack | Redelivered, the Inbox hits, ack. |
| Redis unavailable | The processor throws, so a bounded retry then the DLQ. No result is guessed. Week 10 retry/DLQ. |
| Redis data lost (e.g. container recreated) | Not handled automatically. Redis has a data volume (`infra/docker-compose.yml`), but whether its persistence settings survive a crash without loss is **not verified**. After any Redis loss, warm-up must be re-run before sales open (Week 7 warm-up box). |

**Fixed for Inventory Service (2026-10-02, Week 7):** `OrderPlacedProcessor` used to catch **every** `DbUpdateException` as "a duplicate already recorded the fact". A non-duplicate database error after Redis had reserved was then acked as success and the result was lost. `scripts/verify-cross-store.ps1` reproduced this (5 checks fail on the old code). It now catches only unique violations (PostgreSQL `23505`); any other error is retried and then dead-lettered, and a retry gets `DUPLICATE` from Redis and writes the missing result with no second deduction (TP-I03).

**Known gap (code violates the definition):** `StockResultProcessor` in Order Service still catches **every** `DbUpdateException` as a duplicate. A non-duplicate database error while applying a stock result would be acked and the order left in `PendingStock` until reconciliation. **Closed by:** Week 8, "Close the database exception and publisher-routing P0 risks"
