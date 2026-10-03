# Sequence Diagrams

These are the diagrams for the one workflow the system has: placing an order.
They are drawn from the code as it is on branch `week1-2` (Week 8). Every
arrow is a call that exists in the source. The step numbers match the
numbered steps in `docs/workflow.md`, which names the class behind each step,
its failure branch and its test case.

`scripts/verify-workflow.ps1` checks the diagrams in two ways:

- It compares each claim with the code and configuration.
- It traces real orders through all three services and checks that the
  recorded hops happen in this order.

The `.mmd` files in `report/figures/` must be identical to the blocks below.
The report's PNGs are rendered from them with mermaid-cli 11 and
`report/figures/mermaid-sequence.json`, which wraps long labels so the text
stays readable at page width.

**Changes from the earlier version (2026-10-02, Week 8 box 4):**

- **Nginx removed.** Clients call Order Service directly. `infra/nginx.conf`
  is still the Week 2 placeholder: it answers every request itself and
  forwards nothing. Nginx routing and rate limits arrive in Week 12.
- **Publishers now show routed confirmation (Week 6).** Before publishing,
  each publisher checks that every required subscriber queue exists and is
  bound. It then publishes with `mandatory` and waits for the confirm.
  `StockReserved` needs both `StockReserved` and `ProcessWorker.StockReserved`.
- **Inbox steps are drawn.** In both services the Inbox check comes before
  the business step. The Inbox row commits in the same transaction as the
  Outbox row (Inventory) or the state change (Order Service).
- **The warm-up gate (Week 7) is drawn.** `reserve.lua` reads `sale:open`,
  and `NOT_OPEN` becomes `StockRejected` with nothing deducted.
- **The fork after `StockReserved` is drawn as `par`.** The two consumers run
  concurrently.

## Happy path: stock available

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant OS as Order Service
    participant PGO as PostgreSQL (order_service)
    participant OP as Order Outbox publisher
    participant MQ as RabbitMQ
    participant IS as Inventory Service
    participant R as Redis
    participant PGI as PostgreSQL (inventory_service)
    participant IP as Inventory Outbox publisher
    participant PW as Process Worker

    Client->>OS: POST /api/orders (Idempotency-Key, quantity 1)
    OS->>PGO: look up the Idempotency-Key (not found)
    OS->>PGO: one transaction: INSERT order (PendingStock) + Outbox row OrderPlaced (new MessageId)
    OS-->>Client: 201 Created (state PendingStock)

    loop every 2s
        OP->>PGO: SELECT up to 50 unpublished rows, oldest first
    end
    OP->>MQ: check required queue OrderPlaced exists and is bound
    OP->>MQ: publish OrderPlaced (mandatory, publisher confirm)
    MQ-->>OP: routed and confirmed
    OP->>PGO: mark the row published

    MQ->>IS: deliver OrderPlaced
    IS->>PGI: Inbox: MessageId already processed? (no)
    IS->>R: EVAL reserve.lua (inventory, processed and sale:open keys)
    R-->>IS: RESERVED (stock - 1, order id added to the processed set)
    IS->>PGI: one transaction: Outbox row StockReserved (if none for this OrderId) + Inbox row
    IS->>MQ: ack OrderPlaced

    loop every 2s
        IP->>PGI: SELECT up to 50 unpublished rows, oldest first
    end
    IP->>MQ: check required queues StockReserved and ProcessWorker.StockReserved
    IP->>MQ: publish StockReserved (mandatory, publisher confirm)
    MQ-->>IP: routed and confirmed
    IP->>PGI: mark the row published

    par queue StockReserved
        MQ->>OS: deliver StockReserved
        OS->>PGO: one transaction: Inbox check, PendingStock to Confirmed, Inbox row
        OS->>MQ: ack StockReserved
    and queue ProcessWorker.StockReserved
        MQ->>PW: deliver StockReserved
        PW->>PW: fixed processing delay (200 ms)
        PW->>MQ: check required queue OrderProcessed, publish OrderProcessed (MessageId = OrderId, mandatory, confirm)
        PW->>MQ: ack StockReserved
    end

    MQ->>OS: deliver OrderProcessed
    OS->>PGO: one transaction: Inbox check, Confirmed to Completed, Inbox row
    OS->>MQ: ack OrderProcessed

    Client->>OS: GET /api/orders/{id}
    OS-->>Client: 200 OK (state Completed)
```

The Process Worker has no Inbox. A redelivered `StockReserved` makes it
publish `OrderProcessed` again with the same `MessageId` (the `OrderId`), and
Order Service's Inbox absorbs that copy.

**Race in the `par` block (handled since Week 9).** The two branches are
independent. If `OrderProcessed` (step 28) reaches Order Service before step
22 has committed, the order is still `PendingStock`. Order Service then writes
nothing for it and republishes it onto a delayed retry queue
(`OrderProcessed.retry.1`–`.3`, 2 s / 4 s / 8 s). It is applied once the order
is `Confirmed`, and dead-lettered only if it is still early after three
requeues (`docs/design-decisions.md` §2, TP-M02).

## Rejection path: sold out, or sale not open

```mermaid
sequenceDiagram
    autonumber
    actor Client
    participant OS as Order Service
    participant PGO as PostgreSQL (order_service)
    participant MQ as RabbitMQ
    participant IS as Inventory Service
    participant R as Redis
    participant PGI as PostgreSQL (inventory_service)
    participant IP as Inventory Outbox publisher

    Client->>OS: POST /api/orders (Idempotency-Key, quantity 1)
    OS->>PGO: one transaction: INSERT order (PendingStock) + Outbox row OrderPlaced
    OS-->>Client: 201 Created (state PendingStock)
    Note over OS,MQ: Order Outbox publisher sends OrderPlaced exactly as in the happy path

    MQ->>IS: deliver OrderPlaced
    IS->>PGI: Inbox: MessageId already processed? (no)
    IS->>R: EVAL reserve.lua (inventory, processed and sale:open keys)
    alt sale open, stock is 0
        R-->>IS: REJECTED (nothing deducted)
    else no confirmed warm-up (sale:open missing)
        R-->>IS: NOT_OPEN (nothing deducted)
    end
    IS->>PGI: one transaction: Outbox row StockRejected (if none for this OrderId) + Inbox row
    IS->>MQ: ack OrderPlaced

    loop every 2s
        IP->>PGI: SELECT up to 50 unpublished rows, oldest first
    end
    IP->>MQ: check required queue StockRejected, publish StockRejected (mandatory, confirm)
    IP->>PGI: mark the row published

    MQ->>OS: deliver StockRejected
    OS->>PGO: one transaction: Inbox check, PendingStock to Rejected, Inbox row
    OS->>MQ: ack StockRejected

    Client->>OS: GET /api/orders/{id}
    OS-->>Client: 200 OK (state Rejected)
```

The Process Worker does not subscribe to `StockRejected`, so a rejected order
never reaches it.

`DUPLICATE` (a redelivered `OrderPlaced` whose order already holds a unit)
does not need its own diagram. It follows the happy path from step 14 and
maps to `StockReserved` without deducting again. Because the Outbox row is
"ensure it exists for this OrderId", a redelivery cannot leave the order
waiting with no result.

## Planned hop: Processing (Week 11)

The adopted six-state model (`docs/order-state-machine.md`) adds one hop that
is not built yet:

```mermaid
sequenceDiagram
    participant MQ as RabbitMQ
    participant OrderSvc as Order Service
    participant PGOrd as Postgres (order_service)
    participant ProcSvc as Process Worker
    Note over ProcSvc,OrderSvc: PLANNED (Week 11), not in code yet
    MQ->>ProcSvc: deliver StockReservedEto
    ProcSvc->>MQ: publish OrderProcessingStartedEto
    MQ->>OrderSvc: deliver OrderProcessingStartedEto
    OrderSvc->>PGOrd: UPDATE Order SET state=Processing + history row
    ProcSvc->>ProcSvc: deterministic processing delay
    ProcSvc->>MQ: publish OrderProcessedEto (carries StartedAt)
    MQ->>OrderSvc: deliver OrderProcessedEto
    OrderSvc->>PGOrd: UPDATE Order SET state=Completed + history row
```

If `OrderProcessedEto` arrives before the started event, Order Service applies
`Confirmed → Processing → Completed` in one transaction, with the `Processing`
history row marked as implied. `ProcessingFailed` has no producer
(success-only Process Worker).

## Not drawn as arrows

- **Retry and DLQ branches.** Every consumer and publisher has a failure
  branch. `docs/workflow.md` lists each one with its test case, rather than
  doubling the arrows here.
- **Reconciliation.** `ReconciliationWorker` checks every 30 s for orders
  stuck in `PendingStock` for more than 30 s and writes a new `OrderPlaced`
  Outbox row for them. This is a safety net and is verified in Week 10.
