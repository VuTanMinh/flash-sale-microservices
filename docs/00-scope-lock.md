# Project Scope and Research Questions

**Students:** Vũ Đình Kiệt (523V0011) and Vũ Tấn Minh (523V0012). **Class:** 23K50201.

**Status:** Retrospective Week 1 baseline, reconciled against the teacher brief on 2026-09-30. The teacher brief is authoritative. Changes to the scope require a dated reason and must be recorded here before official experiments.

## Research question

Under the same flash-sale workload and single-EC2-host constraint, how do a deliberately naive implementation (C0), a synchronous PostgreSQL atomic-update baseline (C1), and an asynchronous Redis-Lua/RabbitMQ design (C2) compare in inventory correctness, API latency, order-completion latency, throughput, and overload behavior? For the asynchronous design, how do load shedding (C3) and 1, 2, or 4 Inventory Service replicas on the same host affect rejection, queue drain, throughput, and resource contention?

The target of approximately 2,000 reservation attempts per second is an experimental target on the selected hardware, not a hardware-independent guarantee.

## Questions to answer

1. Does each valid implementation preserve the inventory invariants under concurrent requests for scarce stock?
2. How do C1 and C2 trade request latency, end-to-end completion latency, throughput, and architectural complexity?
3. At overload, do the C3 controls reject excess work predictably and recover after load falls?
4. On one EC2 host, how do 1, 2, and 4 Inventory Service replicas affect throughput, queue drain time, and shared-resource contention?

## In-scope system

- Backend order acceptance, status polling, stock reservation, event delivery, and deterministic downstream processing.
- Order Service owns orders, client idempotency, its Outbox, and its processed-message records.
- Inventory Service owns reservation decisions. Redis Lua performs the atomic stock check/decrement; Inventory Service owns its Outbox and processed-message records.
- Process Worker consumes successful reservation events, publishes `OrderProcessingStarted` when it begins, waits a configured deterministic delay, and publishes a successful completion result (`OrderProcessed`).
- Order states follow the teacher's six-state model; `ProcessingFailed` is declared but has no in-scope trigger (success-only). See `docs/order-state-machine.md`.
- RabbitMQ carries asynchronous events. PostgreSQL is one instance with service-owned schemas and separate service credentials; services must not read another service's schema.
- **Week 2 verification gap:** service connection strings now use separate roles and Compose initializes their schemas and grants, but the setup has not yet been exercised against a fresh and an existing PostgreSQL volume. Keep the infrastructure gate open until both paths are verified.
- Docker Compose is the local development environment. The experiment target is one AWS EC2 instance. JMeter runs on a separate machine.
- Load shedding consists of Nginx rate limiting, application concurrency limiting, and a bounded RabbitMQ queue. It is planned for C3; do not report it as implemented until verified.

## Comparison configurations

| Configuration | Definition | Role |
|---|---|---|
| C0 | Deliberately unsafe read/check/write inventory flow | Demonstrate the race condition; not the correctness or performance baseline |
| C1 | Synchronous conditional atomic inventory update in PostgreSQL | Main baseline; must preserve stock correctness |
| C2 | Asynchronous RabbitMQ workflow with Redis Lua reservation, Outbox, Inbox, retry, and DLQ | Event-driven design under evaluation |
| C3 | C2 plus rate, concurrency, and queue limits | Evaluate controlled overload and recovery |
| C4 | C3 with 1, 2, and 4 Inventory Service consumer replicas on the same EC2 host | Evaluate process/container replication and shared-resource contention |

## Fixed limits and non-goals

- One EC2 host for backend services and dependencies; run JMeter elsewhere to avoid competing with the system under test.
- Replicas run as processes or containers on that same host. Results do not establish multi-node horizontal scaling.
- One PostgreSQL, Redis, and RabbitMQ instance. No cluster, replication, or multi-region claims.
- No frontend, real payment processing, payment-failure compensation, or authentication/authorization. The Process Worker has a deterministic delay and successful outcome only.
- Keep conclusions limited to the tested workload, hardware, configuration, and failure scenarios.

## Acceptance claims

- Inventory never becomes negative, and successful reservations never exceed the seeded stock.
- One order can reserve stock at most once; duplicate message delivery causes no duplicate side effect.
- Overload is rejected deliberately, and the system recovers after load drops.
- Accepted orders reach a terminal state or become visible to reconciliation; the system must not silently lose accepted work.
- Measurements distinguish HTTP acceptance from business completion and include tail latency, throughput, rejection, queue, resource, and correctness results.

## Change log

- 2026-09-30 — Reconstructed the Week 1 scope from the teacher brief and checked it against the Week 11 branch. This records the current baseline; it does not claim the document was frozen on the original Week 1 date.
- 2026-10-01 — Adopted the teacher's six named order states over the four-state source model. `Processing` gets a real trigger (`OrderProcessingStarted`); `ProcessingFailed` stays declared but unreachable under this scope. Source alignment is the Week 11 task.
