# Order API behaviour (Week 5)

Specification for `POST /api/orders` and `GET /api/orders/{id}` (`OrdersController`). Requirements: `docs/teacher-brief.md` §4 ("Tiếp nhận và lưu order", "Trả order ID sau khi request được accepted", "Tra cứu trạng thái order thông qua polling API") and §5 ("Order Service kiểm tra request và client idempotency key"). Tested by `scripts/verify-order-api.ps1` (test cases TP-A01 to TP-A05 in `docs/test-plan.md`).

## Request validation (before any database write)

| Input | Rule | Response |
|---|---|---|
| `Idempotency-Key` header | required, non-blank | 400 if missing or blank |
| `productId` | required, not empty or whitespace | 400 |
| `quantity` | must equal **1** (single-unit flash-sale orders; the reservation script decrements exactly one unit) | 400 for any other value |
| Body | valid JSON | 400 |

A rejected request creates **no** order row and **no** Outbox row. A product id that is valid but has no stock is *not* a validation error: the order is accepted, and Inventory Service decides `StockRejected` asynchronously.

## Idempotency

| Situation | Response |
|---|---|
| New key | 201 Created; body is the order in `PendingStock`. The order row and its `OrderPlaced` Outbox row commit in one transaction. |
| Same key, same body | 200 OK with the **original** order, byte-identical to the first response's order fields |
| Same key, different body (`productId` or `quantity`) | 409 Conflict; the original order is unchanged |
| Same key sent concurrently (several requests before the first commits) | Exactly one order and one Outbox row. One request gets 201 and every other gets 200 with the same order id. **No 5xx.** A request that loses the race on the unique index re-reads the winner's order and answers as a replay (or 409 if its body differs). |

## Polling

| Request | Response |
|---|---|
| `GET /api/orders/{id}` for an existing order | 200 with current `state` and the stage timestamps |
| Unknown id | 404 |

## One order per key

Guaranteed by the unique index `IX_orders_IdempotencyKey` plus the race handling above. Checked under mixed load: 50 keys × 4 concurrent requests must produce exactly 50 orders and 50 Outbox rows, one `201` per key, and the same order id in all four responses for a key (TP-A07).

## State behaviour (current four-state code)

Legal transitions (`Order.LegalTransitions`): `PendingStock → Confirmed`, `PendingStock → Rejected`, `Confirmed → Completed`. Every other pair throws `InvalidOrderStateTransitionException` and changes nothing. Result events are applied by `StockResultProcessor`:

| Event arrives when the order is… | Outcome |
|---|---|
| in the event's target state (duplicate, any `MessageId`) | Ack, no transition; the Inbox row is recorded |
| already past the target on `PendingStock → Confirmed → Completed` (stale, e.g. `StockReserved` after `Completed`) | Ack, no transition; the Inbox row is recorded |
| in a conflicting state (e.g. `StockRejected` after `Confirmed`, anything after `Rejected` except `StockRejected`) | `InvalidOrderStateTransitionException`, nothing recorded, so the consumer dead-letters it |
| unknown order id | Ack as `OrderNotFound`, nothing recorded |
| `OrderProcessed` while still `PendingStock` (early) | **Known gap:** dead-lettered today; defined behaviour is retry (`docs/design-decisions.md` §2, Week 9) |

Verified by `OrderStateBehaviourTests` (full 4×4 transition matrix and the event cases above; TP-A06).

## Timestamps

All timestamps are UTC and serialised with a `Z` suffix. They are stored at microsecond precision, so a value read back from PostgreSQL equals the value returned when the order was created.
