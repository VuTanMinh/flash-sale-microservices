# Event Contract

**Status:** Contract defined (Week 4). Not yet wired to a publisher or
consumer — that's the Transactional Outbox (Week 6) and Inventory Service's
`OrderPlaced` handler / result publication (Weeks 7–8). Defining the shape
now, before the plumbing exists, is deliberate: the checklist's own guidance
is to write the contract doc and the actual C# class definitions together so
the two can't drift apart — there is no separate "spec" to fall out of sync
with the code, the code *is* the spec.

Source of truth for the class definitions: `src/FlashSale.EventContracts/`
(a class library referenced by any service that needs to publish or consume
these events — currently just Order Service; Inventory Service will
reference it too once scaffolded, Week 7, so both sides share one
definition instead of two copies that can drift).

Each event maps directly onto a transition in `docs/order-state-machine.md`.
Only the three transitions that document already commits to as fully
specified get an event here — the `Confirmed → Processing → ...` leg is
still an open question there, so there is deliberately no event for it yet.

## `OrderPlacedEto`

Published by Order Service, consumed by Inventory Service.
Triggers `[*] → PendingStock`.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | Business identifier — the order this event is about. |
| `ProductId` | `string` | Which product's stock to reserve against. |
| `Quantity` | `int` | Always `1` under current scope (single-unit orders); the field exists as `int` rather than hardcoded to keep the contract honest about what it represents, not because multi-quantity orders are planned. |
| `MessageId` | `Guid` | Broker-message-level idempotency key (Week 9 Inbox pattern). Generated once, at publish time (inside the same Outbox transaction as the order insert, Week 6). **Not** the same as the client-supplied `Idempotency-Key` header from Week 5 — see the boundary note below. |

## `StockReservedEto`

Published by Inventory Service, consumed by Order Service.
Triggers `PendingStock → Confirmed`.

| Field | Type | Notes |
|---|---|---|
| `OrderId` | `Guid` | Matches the `OrderPlacedEto.OrderId` that caused this reservation. |
| `ProductId` | `string` | |
| `MessageId` | `Guid` | Inventory Service's own idempotency key for *this* event — a fresh value, not a copy of `OrderPlacedEto.MessageId`. Each service's outbound message gets its own key; see Week 9's note that each consumer needs its own Inbox. |

## `StockRejectedEto`

Published by Inventory Service, consumed by Order Service.
Triggers `PendingStock → Rejected`.

Same shape as `StockReservedEto` — see the code comment in
`StockRejectedEto.cs` for why there is no `Reason` field: the only rejection
cause currently in scope is insufficient stock, so there is nothing yet for
a `Reason` field to distinguish between. Add one only when a second real
cause exists, not speculatively.

## Fields deliberately left out for now

- **`CorrelationId`** — Week 11 adds correlation-ID propagation across every
  event; the checklist's own Week 11 step phrases this as "add it to your
  Week 4 event contract if not already there", i.e. it is expected to arrive
  later, not now. Adding it in Week 4 with nothing yet reading or writing it
  would be exactly the kind of speculative field the scope lock warns against.

## Boundary note (already in `docs/00-scope-lock.md`, repeated here on purpose)

`OrderPlacedEto.MessageId` (broker-redelivery idempotency, Week 9) and the
client-facing `Idempotency-Key` header (duplicate-submission idempotency,
Week 5) solve different problems and must not be conflated — one dedupes
what RabbitMQ might redeliver, the other dedupes what an impatient client
might resubmit.
