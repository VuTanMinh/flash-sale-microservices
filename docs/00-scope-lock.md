# Scope Lock — Flash-Sale Microservices Capstone

**Student:** Vũ Đình Kiệt (523V0011) — Class 23K50201 — TDTU
**Locked:** Week 1 (08/08 – 14/08/2026)
**Status:** Frozen for the semester. Any change to this document after Week 1 is itself
a decision that must be logged (date + reason) in the changelog at the bottom, because
Week 13 requires scope to be locked before official experiments run.

> Source: `de-cuong-cap-nhat.md` / LaTeX proposal, §1 ("Phát biểu bài toán") and §3
> ("Giới hạn"), as summarized in `FLASHSALE_EXECUTION_CHECKLIST.md` Step 1.1. This
> document is the single concrete, implementable statement of that scope — if a
> stranger couldn't build exactly this from reading only this file, it isn't locked yet.

---

## In scope — the four correctness/behavior guarantees

The system must demonstrably provide these four guarantees under concurrent,
large-scale Flash-sale load. Each one is a claim that gets validated experimentally
(Week 8 first pass, Week 14 final pass) — not just asserted in prose.

1. **Bounded reservations** — inventory can never be reserved beyond what actually
   exists. `available_inventory >= 0` and `successful_reservations <= initial_inventory`
   hold at all times, including under concurrent conflicting requests for the same
   product. See `docs/inventory-invariants.md` for the literal testable assertions.
2. **Controlled overload response** — when incoming request rate exceeds what the
   system is provisioned to handle, the system degrades by explicitly rejecting excess
   requests (load shedding at Nginx / application / RabbitMQ layers, built Week 12)
   rather than by silently failing, corrupting state, or crashing.
3. **Replica scalability** — the architecture supports running multiple replicas of
   each service (Order Service, Inventory Service, Process Worker) without correctness
   depending on there being exactly one instance — i.e., no in-memory-only state that
   would break under horizontal scale-out.
4. **Traceable state** — every order's full lifecycle (from `POST /api/orders` to
   terminal state) is reconstructable after the fact from logs/timestamps via a single
   correlation ID (built Week 11), and every state transition is attributable to a
   specific event/service.

## Explicitly out of scope

The following are deliberately **not** built, tested, or claimed as working, this
semester. If a design decision anywhere else in this project seems to require one of
these, that is a signal the design has drifted from scope — flag it, don't quietly
build it.

- Full frontend (this project is API/backend-only; testing is via JMeter + `curl`, not a UI)
- Product catalog, shopping cart, promotions/coupons
- User management / admin panel
- Authentication / authorization (no login, no tokens, no per-user access control)
- Redis Cluster (single Redis Stack instance only)
- RabbitMQ Cluster (single RabbitMQ instance only)
- PostgreSQL replication (single Postgres instance; schema-per-service, not database-per-service)
- Multi-region deployment
- Payment processing, payment failure handling, or compensation/saga logic beyond the
  Process Worker's deterministic simulated downstream step (see Week 11)

## Boundary notes (things that look related but aren't the same claim)

- **Client idempotency key** (Week 5, dedupes duplicate client submissions) is a
  different mechanism from the **Inbox/processed-message pattern** (Week 9, dedupes
  duplicate broker message delivery). Both are in scope; they solve different problems
  and must not be conflated in the report.
- **Reconciliation job** (Week 10) is a safety net for orders stuck in `PendingStock`
  — it does not replace the Outbox pattern, retry logic, or the DLQ. A high
  intervention rate from this job in Week 13/14 experiments is itself a result worth
  reporting, not a bug to hide.
- **Process Worker** (Week 11) simulates downstream processing with a deterministic
  delay and a successful result only — it does not simulate downstream failure or
  implement compensation. See the open question flagged in
  `docs/order-state-machine.md` regarding the `Confirmed → Processing → Completed`
  leg of the state machine.

---

## Changelog

- 2026-08-11 — Initial scope lock written (Week 1, Step 1.1).
