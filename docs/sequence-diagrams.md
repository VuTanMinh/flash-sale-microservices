# Sequence Diagrams

Two diagrams for the one workflow the system has (place an order), split by
outcome. Both represent the **target design** (Weeks 5–9) — Outbox, the
publisher worker, RabbitMQ, and Inventory Service don't exist yet as of
Week 4; this is the design these weeks build toward, not a description of
what currently runs. `docs/order-state-machine.md` is the source of truth
for which transition each arrow corresponds to; `docs/event-contract.md` is
the source of truth for each event's exact shape.

## Happy path — stock available

```mermaid
sequenceDiagram
    actor Client
    participant Nginx
    participant OrderSvc as Order Service
    participant PG as Postgres (order_service schema)
    participant Publisher as Outbox Publisher
    participant MQ as RabbitMQ
    participant InvSvc as Inventory Service
    participant Redis

    Client->>Nginx: POST /api/orders
    Nginx->>OrderSvc: POST /api/orders
    OrderSvc->>PG: INSERT Order (PendingStock) + OutboxEvent (OrderPlaced) — one transaction
    PG-->>OrderSvc: committed
    OrderSvc-->>Client: 202 Accepted (order id, state=PendingStock)

    loop polls unpublished rows
        Publisher->>PG: SELECT unpublished OutboxEvents
    end
    Publisher->>MQ: publish OrderPlacedEto
    MQ-->>Publisher: publisher confirm
    Publisher->>PG: mark OutboxEvent published

    MQ->>InvSvc: deliver OrderPlacedEto
    InvSvc->>Redis: EVAL reserve.lua (product_id, order_id)
    Redis-->>InvSvc: RESERVED
    InvSvc->>MQ: publish StockReservedEto (own outbox pattern, Week 8)
    MQ->>OrderSvc: deliver StockReservedEto
    OrderSvc->>PG: UPDATE Order SET state=Confirmed (same tx as inbox insert, Week 9)

    Client->>Nginx: GET /api/orders/{id}
    Nginx->>OrderSvc: GET /api/orders/{id}
    OrderSvc->>PG: SELECT Order
    PG-->>OrderSvc: state=Confirmed
    OrderSvc-->>Client: 200 OK (state=Confirmed)
```

## Rejection path — out of stock

Identical up through the Redis call; diverges only at the reservation
result. Everything about *how* the request travels is the same — only the
event type and the terminal state differ.

```mermaid
sequenceDiagram
    actor Client
    participant Nginx
    participant OrderSvc as Order Service
    participant PG as Postgres (order_service schema)
    participant Publisher as Outbox Publisher
    participant MQ as RabbitMQ
    participant InvSvc as Inventory Service
    participant Redis

    Client->>Nginx: POST /api/orders
    Nginx->>OrderSvc: POST /api/orders
    OrderSvc->>PG: INSERT Order (PendingStock) + OutboxEvent (OrderPlaced) — one transaction
    PG-->>OrderSvc: committed
    OrderSvc-->>Client: 202 Accepted (order id, state=PendingStock)

    Publisher->>MQ: publish OrderPlacedEto
    MQ->>InvSvc: deliver OrderPlacedEto
    InvSvc->>Redis: EVAL reserve.lua (product_id, order_id)
    Redis-->>InvSvc: REJECTED (stock <= 0)
    InvSvc->>MQ: publish StockRejectedEto
    MQ->>OrderSvc: deliver StockRejectedEto
    OrderSvc->>PG: UPDATE Order SET state=Rejected

    Client->>Nginx: GET /api/orders/{id}
    Nginx->>OrderSvc: GET /api/orders/{id}
    OrderSvc->>PG: SELECT Order
    PG-->>OrderSvc: state=Rejected
    OrderSvc-->>Client: 200 OK (state=Rejected)
```

## What's deliberately not shown

Neither diagram extends into `Confirmed → Processing → Completed`. Per
`docs/order-state-machine.md`, that leg's trigger isn't resolvable yet — it
depends on the Week 11 Process Worker design. Drawing it here would mean
inventing a mechanism, which is exactly what that document says not to do.
Redraw both diagrams once Week 11 answers that question, rather than
guessing now and quietly leaving a wrong diagram in the report.
