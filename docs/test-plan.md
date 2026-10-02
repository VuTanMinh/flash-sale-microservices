# Test Plan

**Rule:** a case is `PASS` only when its evidence file is committed in this repository and shows the pass. A case with no saved evidence is `NOT RUN`, even if it was checked by hand earlier. Earlier versions of this plan marked tests as "Built" for Inventory Service and the Process Worker; those tests do not exist, so the claims were removed. `scripts/verify-test-plan.ps1` enforces the rule.

**Sources:** requirements from `docs/teacher-brief.md`; cases follow the Notion roadmap boxes ("Roadmap" column); design rules from `docs/design-decisions.md`; invariants from `docs/inventory-invariants.md`.

**Status values:** `PASS` (evidence committed), `FAIL` (evidence shows failure), `NOT RUN` (no evidence yet). `Planned:` in a command means the script does not exist yet and is written by that roadmap box.

## Environment and build

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-E01 | Fresh environment: SDK, clean build, own-account migrations, isolation, ERD | W02 | New PostgreSQL volume with `infra/initdb`; repo at the commit under test | SDK matches `global.json`; 0 build errors; both migrations as their own accounts; Order Service answers `POST /api/c1/orders` with 200; 7 isolation checks; 29 ERD checks | `scripts/verify-environment.ps1 -Mode Fresh` | PASS | `tests/evidence/20261001T114318Z-environment-fresh.log` |
| TP-E02 | Existing-database role migration | W02 | Copy of the running local DB; role script applied twice | Same checks as TP-E01 after the migration; Inventory history moved to `inventory_service` | `scripts/verify-environment.ps1 -Mode Existing` | PASS | `tests/evidence/20261001T114318Z-environment-existing.log` |
| TP-E03 | Unit tests (Order Service: state machine and state behaviour, Outbox atomicity, duplicate message) | W05, W06, W09 | `tests/FlashSale.OrderService.Tests` | 43 of 43 pass | `dotnet test tests/FlashSale.OrderService.Tests --logger trx` | PASS | `tests/evidence/20261001T123816Z-unit-tests.trx` |

## Baseline (C0/C1)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-B01 | C0 race captured | W03 | `c0-demo-product` stock 1; 5 concurrent attempts | More than 1 Confirmed; final stock = 1 − Confirmed < 0 | `scripts/run-baseline.ps1` | PASS | `tests/baseline/results/20261001T112439Z-c0-race.json` |
| TP-B02 | C1 below/equal/above stock, 3 runs each | W03 | `c1-demo-product` stock 100; 50 / 100 / 150 concurrent requests | All HTTP 200; Confirmed = min(demand, 100); stock ≥ 0 and conserved; one log row per request | `scripts/run-baseline.ps1` | PASS | `tests/baseline/results/20261001T112439Z-summary.md` |
| TP-B03 | Reset/seed repeatable with exact values | W03 | Seeded DB, then deliberately corrupted | c0=1, c1=1, flash-product-1=1000, 0 order rows, identical across 3 runs | `scripts/verify-reset-seed.ps1` | PASS | `tests/baseline/results/20261001T090034Z-reset-seed.log` |
| TP-B04 | JMeter C1 smoke with assertions | W03 | `tests/jmeter/smoke-test.jmx`, 10 threads, `flash-product-1` | 10/10 samples on `/api/c1/orders`, HTTP 200, assertions pass; DB 10 Confirmed, stock 990 | `scripts/run-jmeter-smoke.ps1` | PASS | `tests/jmeter/results/20261001T112429Z-c1-smoke-summary.md` |

## Documentation consistency

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-D01 | Requirements chapters trace the teacher brief | W02 | `report/report.tex`, brief items | All 40 brief items traced | `scripts/verify-requirements-trace.ps1` | PASS | `tests/evidence/20261001T114318Z-requirements-trace.log` |
| TP-D02 | Baseline report section matches saved evidence | W03 | Report §C0/C1, baseline JSON, smoke JTL | Every number matches the evidence | `scripts/verify-baseline-report.ps1` | PASS | `tests/evidence/20261001T114318Z-baseline-report.log` |
| TP-D03 | Design artifacts align with source | W04 | Class diagram, API/event contracts, state model, sequence diagrams | 51 checks pass (live API comparison when `-BaseUrl` is given) | `scripts/verify-design-alignment.ps1` | PASS | `tests/evidence/20261001T114318Z-design-alignment.log` |
| TP-D04 | Design decisions cite real code; known gaps still present | W04 | `docs/design-decisions.md` | 26 checks pass | `scripts/verify-design-decisions.ps1` | PASS | `tests/evidence/20261001T114318Z-design-decisions.log` |

## Order API (Week 5)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-A01 | Accepted intake and polling | W05 | `POST /api/orders` with a new key, then `GET /api/orders/{id}` | 201 with `PendingStock`; GET returns the same order | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123317Z-order-api.log` |
| TP-A02 | Request validation, quantity = 1 | W05 | Missing key; quantity 0, 2; empty product | 400 for each; no order row created | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123317Z-order-api.log` |
| TP-A03 | Unchanged-payload replay | W05 | Same key + same body twice | Second call 200 with the same order id; one row | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123317Z-order-api.log` |
| TP-A04 | Changed-payload conflict | W05 | Same key, different body | 409; original order unchanged | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123317Z-order-api.log` |
| TP-A05 | Concurrent retries of one key | W05 | 20 concurrent posts, same key + body | Exactly one order row and one Outbox row; every response carries that order id | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123317Z-order-api.log` |
| TP-A06 | Legal/duplicate/invalid state transitions | W05 | Transition matrix on `Order.TransitionTo` | Legal succeed; illegal throw; duplicate result is a no-op | `dotnet test tests/FlashSale.OrderService.Tests` (`OrderStateBehaviourTests`) | PASS | `tests/evidence/20261001T123816Z-unit-tests.trx` |
| TP-A07 | One order per Idempotency-Key under mixed concurrent load | W05 | 50 keys × 4 concurrent identical requests | Every response 201/200; one 201 and one order id per key; exactly 50 orders and 50 Outbox rows; no duplicate key in the table | `scripts/verify-order-api.ps1` | PASS | `tests/evidence/20261001T123816Z-order-api.log` |

## Outbox and publication (Week 6)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-O01 | Atomic order/event commit and rollback; stable MessageId on retry | W06 | Throwaway DB + broker; Outbox INSERT revoked for one request; broker down, then up | Commit: one order + one unpublished Outbox row. Refused Outbox insert: request fails, no order row. Retries keep the payload; once the broker is up exactly one message arrives with the MessageId stored at commit | `scripts/verify-outbox.ps1` | PASS | `tests/evidence/20261001T163530Z-outbox.log` |
| TP-O02 | Routing, missing bindings, returns/negative confirms, broker interruption | W06 | Throwaway broker + Redis: valid route; required queue deleted; binding removed; broker stopped; full queue with reject-publish; unroutable probe; Process Worker queue missing for StockReserved; OrderProcessed queue missing | No row marked published unless every required queue received the message; each fault leaves the row unpublished and it is delivered exactly once after recovery; StockReserved reaches both required queues; the worker dead-letters rather than loses | `scripts/verify-publication.ps1` | PASS | `tests/evidence/20261001T163055Z-publication.log` |

## Inventory reservation (Week 7)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-I01 | Warm-up readiness gate | W07 | Reservation before warm-up (Lua and end to end through Inventory Service); warm-up re-run on an open sale; -Force | NOT_OPEN / StockRejected with no stock touched before a confirmed warm-up; warm-up confirms every product; an open sale is not reset without -Force | `scripts/verify-inventory.ps1` | PASS | `tests/evidence/20261002T051418Z-inventory.log` |
| TP-I02 | Lua outcomes and hot-product contention | W07 | Hot product: 100 units, 300 distinct orders + 100 repeats concurrently; skewed: 4 products (40/30/20/10 units), 250 orders weighted 50/25/15/10 + 80 repeats | Per product: inventory ≥ 0, reservations ≤ initial, inventory + reservations = initial, RESERVED = min(demand, stock); no order reserved twice; DUPLICATE only for orders holding a unit | `scripts/verify-inventory.ps1` (`tests/InventoryProbe`) | PASS | `tests/evidence/20261002T051418Z-inventory.log` |
| TP-I03 | PostgreSQL failure after Redis reservation | W07 | Outbox INSERT revoked after reserve.lua ran; case 1 restored within the retry window; case 2 restored after the message was dead-lettered, then the dead letter replayed | Exactly one deduction; the message is never acked while the result is missing; a retry or replay gets DUPLICATE and writes StockReserved | `scripts/verify-cross-store.ps1` | PASS | `tests/evidence/20261002T052244Z-cross-store.log` |

## Workflow and correctness (Week 8)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-W01 | StockReserved/StockRejected drive order status | W08 | Orders via the API; StockReserved / StockRejected published as Inventory would; redelivery; same result as new message; conflicting result; unknown order; Inbox INSERT refused | Confirmed / Rejected with one Inbox row each; duplicates change nothing; conflict dead-lettered with nothing recorded; unknown order acked; refused Inbox insert rolls back the state change | `scripts/verify-stock-results.ps1` | PASS | `tests/evidence/20261002T061249Z-stock-results.log` |
| TP-W02 | Validator proves all four invariants for C1 and C2, no false green | W08 | Fixtures: correct C1/C2 runs and broken ones (oversold, unlogged deduction, reservation/order mismatch, double deduction, unsettled, missing data, DB unreachable); real C1 run (30 requests, 20 units) and real end-to-end C2 run (40 requests incl. retries, 20 units, all three services) | Correct runs pass; each broken run fails the targeted invariant (or INCONCLUSIVE / SETUP ERROR), never a pass; both real runs pass all four invariants | `scripts/verify-validator.ps1`, `scripts/verify-real-runs.ps1` | PASS | `tests/evidence/20261002T062442Z-validator.log` |
| TP-W03 | Database exception P0 | W08 | Order Service applying StockReserved with the Inbox INSERT refused: short outage (fixed within the retry window) and long outage (dead-lettered, then replayed); a genuine redelivery afterwards | Never acked as a duplicate: retried, then dead-lettered; applied once the fault clears (Confirmed, one Inbox row); a real duplicate is still a no-op. Publisher routing re-verified (TP-O02 re-run) | `scripts/verify-db-exceptions.ps1` | PASS | `tests/evidence/20261002T063611Z-db-exceptions.log` |

## Delivery semantics (Week 9)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-M01 | Inbox uniqueness; crash after commit before ack | W09 | Kill the consumer between commit and ack | Redelivery is a no-op; one effect | Planned: `scripts/verify-delivery.ps1` | NOT RUN | — |
| TP-M02 | Concurrent duplicates, new MessageId for the same order, out-of-order completion | W09 | Parallel duplicate deliveries; reconciliation re-publish; `OrderProcessed` before `StockReserved` | One stock deduction, one applied result; early completion retried, not dead-lettered (`docs/design-decisions.md` §2 gap) | Planned: `scripts/verify-delivery.ps1` | NOT RUN | — |

## Failure handling (Week 10)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-F01 | Bounded retry and service DLQ | W10 | Transient then permanent handler failure | 4 attempts (1 s/2 s/4 s), then the correct service's DLQ | Planned: `scripts/verify-failures.ps1` | NOT RUN | — |
| TP-F02 | Stuck PendingStock detection and recovery | W10 | Order with no stock result | Reconciliation re-triggers after the timeout; outcome preserved across restart | Planned: `scripts/verify-failures.ps1` | NOT RUN | — |

## Worker and observability (Week 11)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-P01 | Deterministic worker under replay, restart, reordering | W11 | Replayed `StockReserved`, worker restart | One applied completion per order | Planned: `scripts/verify-worker.ps1` | NOT RUN | — |
| TP-P02 | Processing state and history; ProcessingFailed unreachable | W11 | Normal and reordered worker events | `PendingStock → Confirmed → Processing → Completed` history; no handler reaches `ProcessingFailed` | `dotnet test` + Planned: `scripts/verify-worker.ps1` | NOT RUN | — |
| TP-P03 | Trace one order across services | W11 | One order with a known `X-Correlation-ID` | Logs from all three services and the four timestamps reconstruct the path | Planned: `scripts/trace-order.ps1` | NOT RUN | — |

## Overload, deployment, experiments (Weeks 12–14)

| ID | Case | Roadmap | Inputs | Expected outcome | Command | Status | Evidence |
|---|---|---|---|---|---|---|---|
| TP-L01 | Nginx rate limit, concurrency limit, bounded queue | W12 | Load above each limit | Excess rejected early (429/503) before an order is created; queue bounded | Planned: JMeter overload plan | NOT RUN | — |
| TP-L02 | Overload drain and recovery | W12 | Overload, then load drops | Backlog drains; stable without restart; invariants hold | Planned: JMeter overload plan + `scripts/validate-correctness.ps1` | NOT RUN | — |
| TP-L03 | EC2 deployment with separate JMeter host | W12 | Terraform apply | One EC2 backend; only the API reachable from the JMeter host | Planned: Terraform + runbook | NOT RUN | — |
| TP-X01 | Pilot C1–C4 with 1/2/4 Inventory consumers | W13 | Frozen workload matrix | Correctness gates pass; bottlenecks identified | Planned: run manifest scripts | NOT RUN | — |
| TP-X02 | Official runs, 3–5 repetitions per cell | W14 | Frozen configuration | Raw data, validator output and figures per run | Planned: run manifest scripts | NOT RUN | — |
| TP-X03 | README reproduction on a fresh environment | W14 | New machine, README only | A validated run and its figures reproduce | README | NOT RUN | — |

## Out of scope

Per `docs/00-scope-lock.md` and `docs/teacher-brief.md` §3: no frontend tests, no authentication/authorization tests, no cluster, replication or multi-region tests, and no payment-failure tests (the Process Worker is success-only).
