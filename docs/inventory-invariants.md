# Inventory Invariants — Testable Assertions

**Status:** Week 1 draft. These four invariants are used verbatim by the automated
correctness validator (`scripts/validate-correctness.ps1`, built Week 8, reused
unmodified in Week 14 against real experimental data). Per Step 1.3's own verification
criterion, each invariant below is phrased so it can be checked with one concrete
query against a live system — not left as prose.

Schema/key names below (`orders`, `inventory:{productId}`, `processed:{productId}`,
`processed_messages`) match the Week 2 ERD (`docs/erd.md`) and Week 7 Redis design
(`scripts/redis/reserve.lua`); update this file if either of those names change later,
since the validator script depends on this exact vocabulary.

---

## Invariant 1 — Available inventory never goes negative

`available_inventory >= 0`, always, for every product, at every point in time.

- **Redis query:** `GET inventory:{productId}` — the Lua script (Week 7) only issues
  `DECR` after confirming `stock > 0` in the same atomic script invocation, so this
  should hold structurally; the validator samples it anyway as a live check, not a
  design assumption.
- **Fails if:** any code path decrements stock outside the Lua script (e.g. a C0-style
  read-then-write from application code — see Week 3's deliberately-broken baseline).

## Invariant 2 — Successful reservations never exceed initial inventory

`successful_reservations <= initial_inventory`, per product, for a given experiment run.

- **SQL query:**
  ```sql
  SELECT product_id, COUNT(*) AS successful_reservations
  FROM order_service.orders
  WHERE state IN ('Confirmed', 'Processing', 'Completed')
  GROUP BY product_id;
  ```
  Compare each `successful_reservations` value against the `initial_inventory` value
  used to seed that product in `scripts/seed.sql` for the run — it must never be greater.
- **Fails if:** Invariant 1 already fails (they're closely related), or if a
  reservation is double-counted due to a retry/redelivery not being deduplicated.

## Invariant 3 — At most one successful reservation per order

`count(successful reservations per order_id) <= 1` — a single order can never
reserve stock twice, even under retry or redelivery.

- **Redis query (reservation-level, enforced by the Lua script itself):**
  `SISMEMBER processed:{productId} {order_id}` — before this invariant is even
  queried post-hoc, the Lua script (Week 7) refuses a second `DECR` for an
  `order_id` already present in this set, returning `DUPLICATE` instead of `RESERVED`.
- **SQL query (state-level, post-hoc check):** given `order_id` is the primary key
  of `order_service.orders` (see `docs/erd.md`), a duplicate reservation for one
  order can't show up as a duplicate row — it would show up as a state anomaly
  instead. There is nothing to query here beyond Invariant 3's Redis check above;
  this bullet is intentionally not "TBD" anymore, it's "not applicable by
  construction," which is itself worth stating explicitly rather than leaving a
  placeholder query that implies a check that doesn't actually exist.
- **Fails if:** the Redis `processed:{productId}` set check and the RabbitMQ-level
  Inbox check (Invariant 4) are conflated or one is skipped — they are two distinct
  idempotency layers per `docs/00-scope-lock.md`'s boundary notes, and both must hold
  independently.

## Invariant 4 — Duplicate message delivery never produces a second stock deduction

At-least-once delivery (RabbitMQ's actual guarantee) must never translate into more
than one real stock deduction for the same underlying message.

- **SQL query:**
  ```sql
  SELECT message_id, COUNT(*) AS delivery_count
  FROM processed_messages
  GROUP BY message_id
  HAVING COUNT(*) > 1;
  ```
  Must return zero rows — the `UNIQUE` constraint on `message_id` (Week 9) should make
  this structurally impossible once built, so this query is the live proof, not a
  formality.
- **Cross-check:** for any `message_id` that was redelivered (visible in RabbitMQ logs
  / consumer logs as "received twice"), confirm the corresponding stock value only
  moved once — i.e. redelivery produced exactly one Redis `DECR`, not two.
- **Fails if:** the inbox row is inserted *before* processing completes rather than in
  the same transaction as the business update (the exact mistake flagged as a ⚠️ in
  Week 9, Step 9.2 — a crash between those two steps would let this invariant
  silently and incorrectly report success).

---

## Parameterization requirement (Week 8 reminder)

`scripts/validate-correctness.ps1` must accept product ID(s) and expected initial
stock as parameters, not hardcode them — Week 13/14 runs this against several
different product/stock configurations, and a hardcoded validator would silently
validate the wrong data.
