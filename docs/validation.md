# Correctness validation (Week 8)

`scripts/validate-correctness.ps1 -Config C1|C2 -ProductId <id> -InitialStock <n>` checks the four inventory invariants from `docs/teacher-brief.md` §2b and §6 ("Correctness Validation") for one product after a run. `scripts/verify-validator.ps1` proves it (TP-W02).

## What changed and why (code check, 2026-10-02)

The previous validator could not validate C1 at all (it read Redis and the async `orders` table, while C1 lives in `order_service.inventory` / `baseline_orders`). Two of its four C2 checks were tautologies that could never fail:

- **Invariant 3** counted duplicate order **primary keys**, which the primary key makes impossible.
- **Invariant 4** counted duplicate `MessageId`s in `processed_messages`, which its unique index makes impossible.

So a run that double-deducted stock passed. Demonstrated on a fixture where 3 units were taken for 2 reserved orders: the old validator printed PASS for all four and exited 0, and the new one fails invariant 4 and exits 1. It also had a `PENDING` status that did not fail, hard-coded container names, and no handling for an unsettled run.

## Rules per configuration

| Invariant | C1 (PostgreSQL atomic update) | C2 (Redis + event-driven) |
|---|---|---|
| 1. available inventory ≥ 0 | `inventory.stock ≥ 0` | Redis `inventory:{id} ≥ 0` |
| 2. successful reservations ≤ initial stock | Confirmed decisions ≤ initial | `SCARD processed:{id}` ≤ initial **and** successful orders (Confirmed/Processing/Completed) ≤ initial |
| 3. one reservation per order | units taken (initial − stock) = Confirmed decisions (every deduction has exactly one logged decision) | the Redis reservation set and the successful orders are **the same set of order ids**: no successful order without a reservation, no reservation whose order is not successful |
| 4. duplicate message never double-deducts | **NOT APPLICABLE**: C1 is synchronous; no broker messages exist | units taken (initial − stock) = distinct reserved orders, **and** the Inbox `MessageId` unique index exists in both services |

## Statuses

| Status | Meaning | Exit |
|---|---|---|
| PASS | invariant holds | 0 (if all pass/n.a.) |
| FAIL | invariant violated | 1 |
| INCONCLUSIVE | no data for the product, or the run is not settled (a reserved order is still `PendingStock`) | 1 |
| NOT APPLICABLE | only C1 invariant 4, with the reason printed | does not fail |
| SETUP ERROR | database/Redis unreachable, key or row missing, query failed | 1 |

Nothing that was not actually checked is ever reported as PASS.
