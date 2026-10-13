# Event Contract

**Status:** Defined Week 4, fully wired and exercised end to end as of
Week 11 — every event below has a real publisher, a real consumer, and has
been observed flowing through a live system. (This header previously read
"Not yet wired to a publisher or consumer"; the plumbing arrived across
Weeks 6–8 for the first three events and Week 11 for the fourth.) Defining
the shapes before the plumbing existed was deliberate: the checklist's own
guidance is to write the contract doc and the actual C# class definitions
together so the two can't drift apart — there is no separate "spec" to fall
out of sync with the code, the code *is* the spec.

Source of truth for the class definitions: `src/FlashSale.EventContracts/`
(a class library referenced by any service that needs to publish or consume
these events — currently just Order Service; Inventory Service will
reference it too once scaffolded, Week 7, so both sides share one
definition instead of two copies that can drift).

Each event maps directly onto a transition in `docs/order-state-machine.md`.

**Update (Week 11):** this contract gained the fourth event,
`OrderProcessedEto`, below, and every event gained a `CorrelationId`.

**Update (Week 11 box 2):** the fifth event, `OrderProcessingStartedEto`, is now
in code — published by the Process Worker before its deterministic delay — and
`OrderProcessedEto` gained `ProcessingStartedAt`. `OrderProcessedEto` now drives
`Processing → Completed` (or the implied `Confirmed → Processing → Completed`
when the start event has not arrived). `ProcessingFailed` is declared but has no
producer (success-only Process Worker) and stays unreachable by design.

## `OrderPlacedEto`

Published by Order Service, consumed by Inventory Service.
Triggers `[*] → PendingStock`.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | Business identifier — the order this event is about. |
| `ProductId` | `string` | Which product's stock to reserve against. |
| `Quantity` | `int` | Always `1` under current scope (single-unit orders); the field exists as `int` rather than hardcoded to keep the contract honest about what it represents, not because multi-quantity orders are planned. |
| `MessageId` | `Guid` | Broker-message-level idempotency key (Week 9 Inbox pattern). Generated once, when the Outbox row is written (inside the same transaction as the order insert, Week 6), and stored in the payload, so every publish retry sends the same value. **Not** the same as the client-supplied `Idempotency-Key` header from Week 5 — see the boundary note below. |
| `CorrelationId` | `string` | Copied unchanged from the inbound request (see below). |

## `StockReservedEto`

Published by Inventory Service, consumed by Order Service **and** the Process
Worker (each through its own queue bound to the same routing key).
Triggers `PendingStock → Confirmed`.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | Matches the `OrderPlacedEto.OrderId` that caused this reservation. |
| `ProductId` | `string` | |
| `MessageId` | `Guid` | Inventory Service's own idempotency key for *this* event — a fresh value, not a copy of `OrderPlacedEto.MessageId`. Each service's outbound message gets its own key; see Week 9's note that each consumer needs its own Inbox. |
| `CorrelationId` | `string` | Copied unchanged from the inbound request (see below). |

## `StockRejectedEto`

Published by Inventory Service, consumed by Order Service.
Triggers `PendingStock → Rejected`.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | Matches the `OrderPlacedEto.OrderId` that was rejected. |
| `ProductId` | `string` | |
| `MessageId` | `Guid` | Inventory Service's own idempotency key for this event. |
| `CorrelationId` | `string` | Copied unchanged from the inbound request (see below). |

Same shape as `StockReservedEto` — see the code comment in
`StockRejectedEto.cs` for why there is no `Reason` field: the only rejection
cause currently in scope is insufficient stock, so there is nothing yet for
a `Reason` field to distinguish between. Add one only when a second real
cause exists, not speculatively.

## `OrderProcessedEto`

Published by the Process Worker, consumed by Order Service.
Triggers `Processing → Completed`; if it arrives while the order is still
`Confirmed` (the start event has not landed), Order Service applies
`Confirmed → Processing → Completed` in one transaction with the `Processing`
history row implied. Added Week 11.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | The order whose downstream processing finished. |
| `MessageId` | `Guid` | **Set equal to `OrderId`**, unlike every other event here, which mints a fresh value per hop. Step 11.1 specifies that the Process Worker "uses order_id as its own idempotency key", and it is the one service with no database to record what it has already handled. Deriving the key from the order id means a redelivered `StockReserved` regenerates an `OrderProcessed`, which Order Service's Week 9 Inbox then drops — the idempotency key travels in the message instead of living in a store. Verified live in Week 11, not just argued: a republished `StockReserved` caused a second processing run whose completion was deduped, leaving `completed_at` unchanged. *(Not re-verified; see TP-P01 in `docs/test-plan.md`.)* |
| `CorrelationId` | `string` | Carried through from `StockReservedEto`. |
| `ProcessingStartedAt` | `DateTime?` | The Worker's start time (Week 11 box 2) — the same instant it published `OrderProcessingStartedEto.StartedAt`, copied here so an out-of-order completion can record the implied `Processing` history row with the Worker's start time. Nullable because an `OrderProcessed` from an earlier Worker version omits it; when absent, Order Service stamps the implied row with the apply time. |

No `Result`/`Success` field, and no `ProductId` — see the class's own doc
comment: the outcome is deterministically successful under the current scope
lock, and a flag with one possible value carries no information.

## `OrderProcessingStartedEto`

Published by the Process Worker when it begins work on a reserved order (before
its deterministic delay), consumed by Order Service. Triggers
`Confirmed → Processing`. Added Week 11 box 2.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | The order whose processing started. |
| `MessageId` | `Guid` | Derived deterministically from `OrderId` (never a fresh Guid, never the `OrderId` itself), so a redelivered `StockReserved` regenerates a message with the same `MessageId` (its `StartedAt` can differ; the Inbox dedupes by `MessageId`). The derivation is a name-based UUID (v5-style, SHA-1) over the fixed namespace GUID `9e1b5c2a-3d4f-4a6b-8c7d-0e9f1a2b3c4d` plus the `OrderId` bytes (`Guid.ToByteArray()`), with the version-5 and RFC 4122 variant bits set; see `OrderProcessingStartedEto.DeriveMessageId`. It must differ from `OrderId` (which `OrderProcessedEto` uses) so the Inbox can tell a start event apart from the completion it precedes. |
| `CorrelationId` | `string` | Carried through from `StockReservedEto`. |
| `StartedAt` | `DateTime` | When processing began (before the delay), also carried on `OrderProcessedEto.ProcessingStartedAt` so an out-of-order completion can record an implied `Processing` step (see `docs/order-state-machine.md`). |

## Routing (as configured in code)

| Event | Exchange | Routing key | Queue(s) |
|---|---|---|---|
| `OrderPlacedEto` | `flashsale.order.exchange` (direct) | `OrderPlaced` | `OrderPlaced` (Inventory Service) |
| `StockReservedEto` | `flashsale.order.exchange` | `StockReserved` | `StockReserved` (Order Service), `ProcessWorker.StockReserved` (Process Worker) |
| `StockRejectedEto` | `flashsale.order.exchange` | `StockRejected` | `StockRejected` (Order Service) |
| `OrderProcessingStartedEto` | `flashsale.order.exchange` | `OrderProcessingStarted` | `OrderProcessingStarted` (Order Service) |
| `OrderProcessedEto` | `flashsale.order.exchange` | `OrderProcessed` | Order Service's `OrderProcessed` queue |

Dead-lettering goes through `flashsale.dlx`; retry and DLQ behaviour belongs to
Week 10.

## `CorrelationId` — added to every event in Week 11

Week 4 left this out deliberately (the note that used to sit here said it was
"expected to arrive later, not now", since nothing yet read or wrote it).
Step 11.2 is that later. All four events above now carry it, and it behaves
differently from every other identifier in this contract:

- `MessageId` is **regenerated at every hop** — each service mints its own for
  each outbound message, because each consumer needs its own Inbox key.
- `CorrelationId` is **copied unchanged at every hop**, from the inbound HTTP
  request all the way to `OrderProcessed`. That invariance is the entire
  point: one value greps the whole journey out of three services' logs.
- `OrderId` is the business key, and is neither of those things — it is stable
  like a correlation id, but it only exists once an order does, whereas a
  correlation id identifies the *request*, including log lines written before
  or without one.

Order Service does not mint the value itself: it takes ABP's existing
`ICorrelationIdProvider`, which is already populated from the caller's
`X-Correlation-Id` header (or generated per request) by
`app.UseCorrelationId()`. Minting a second id would have made the HTTP log
lines and the order row disagree about what the request is called.

## Boundary note (already in `docs/00-scope-lock.md`, repeated here on purpose)

`OrderPlacedEto.MessageId` (broker-redelivery idempotency, Week 9) and the
client-facing `Idempotency-Key` header (duplicate-submission idempotency,
Week 5) solve different problems and must not be conflated — one dedupes
what RabbitMQ might redeliver, the other dedupes what an impatient client
might resubmit.
