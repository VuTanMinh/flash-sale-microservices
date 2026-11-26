# Full project check of b451b4c, 22 November 2026

Verification only: no service code, configuration, script, test or report changed. `src/`, `infra/`,
`scripts/` and `tests/` (outside `tests/evidence/`) are byte-identical to 88be225, the code of the
14 November regression (`git diff --stat 88be225 b451b4c` on those paths is empty); every later commit
touched only the report, the docs and the demo page. Every Docker check ran on throwaway containers
(verifier PostgreSQL `verify-env-pg` on port 56432, rebuilt fresh before each database check; each
verifier's own RabbitMQ and Redis), never on the owner's local stack. Everything ran from a clean git
clone of b451b4c on E: (D: carries a low-integrity label), one verifier at a time.

## Results that count

| Check | Result | Log |
|---|---|---|
| Build, solution + Process Worker tests + probes, Debug and Release | 0 warnings, 0 errors (8 builds) | `build-*.log` |
| Unit tests, Order Service, with the PostgreSQL race tests (`FLASHSALE_TEST_PG` set) | 104/104, 0 skipped | `unit-OrderService-postgres.log`, `.trx` |
| Unit tests, Process Worker | 7/7 | `unit-ProcessWorker.log`, `.trx` |
| design-chapter 44, test-plan 287, freeze 106, design-alignment 53, design-decisions 28, requirements-trace 40, observability-report 22, workflow (static) 38, baseline-report 19, order-report 23, publication-report 25, inventory-report 29, delivery-report 38, failure-report 103 | all PASS | `static/01-...` to `static/14-...` |
| failure-report -SelfTest (one changed number must be caught) | caught (1 FAIL, as designed) | `static/15-failure-report-negative.log` |
| deployment (offline + 3 image builds; the 2 live parts SKIP, they need the AWS JMeter host) | 25/25 | `static/16-deployment.log` |
| environment (49 checks, before every database check) | PASS every time (28 runs) | `NN-environment.log` |
| erd 32, reset-seed 8, validator 28, real-runs 7, workflow live 66, outbox 12, publication 18, inventory 36, cross-store 11, stock-results 10, db-exceptions 7, delivery 41, delivery-ordering 44, failures 74, reconciliation 35, processing 41, worker 56, metrics 17, message-timestamps 40, extract 57, load-shedding 45, replicas 5, run-collector 30, write-failures 40 | all PASS, 0 FAIL | `02-...` to `52-...` |
| delivery -NegativeControlForgetReservation | fails 3 checks, as designed (the "exactly 1 unit" checks) | `26-delivery-negative.log` |
| ec2-stack (local, own Compose project) | 89/89 | `53-ec2-stack.log` |
| order-api (Order Service on 5100, `Maximum Pool Size=60` as configured, broker unreachable) | 30/30; 0 HTTP 500 in the service log | `56-order-api.log` |

## One intermittent failure

`36-worker.log`: 55 PASS, 1 FAIL, "E1: the Worker exited by itself after Ctrl+C (no force)". After a
real Ctrl+C the Process Worker was still running when the verifier stopped waiting (30 s). Every other
E1 check passed: the in-flight orders went back to the queue, nothing was dead-lettered, no error was
logged, and after the restart every order completed. The rerun alone, `38-worker.log`, passed 56/56,
and all 13 earlier worker logs in `tests/evidence/` (11 October to 14 November) passed this check. Not diagnosed: the Worker leaves the
.NET host's shutdown timeout at its 30 s default, the same length as the verifier's wait, so a slow
shutdown can lose that race. Recorded as a flaky check, not a defect; no code was changed (Week 15).

## False-positive check (`negative/`)

A PASS only counts if its check can fail. Each committed negative control's deliberate break was
recreated in its own scratch clone on E: (never in the repository), built (0 errors in every case),
run on a fresh `verify-env-pg`, and compared with the committed log. Every break made its verifier fail.

| Committed control | Break recreated | FAIL now / committed | Note |
|---|---|---|---|
| 20261002T152659Z-workflow-negative-control | Worker `RequiredSubscriberQueues` OrderProcessed = `NoSuchQueue` | 7 / 6 | the same 6, plus the Processing-step check added in Week 11 |
| 20261002T183238Z-delivery-negative-no-inbox-check | Inventory `OrderPlacedProcessor` Inbox check forced to false | 1 / 1 | same check |
| 20261002T183238Z-delivery-negative-ack-before-commit | Inventory `OrderPlacedConsumer` acks before processing | 12 / 24 | every Inventory check of the committed run fails again, plus the newer Reserve-crash cases; the committed run's knock-on failures in the StockResult, OrderProcessed and Worker crash cases do not recur, correctly, since those consumers are not broken |
| 20261003T181814Z-delivery-ordering-negative-early-completion | **equivalent, not exact**: an early `OrderProcessed` throws instead of being requeued (dead-lettered after retries, the pre-fix behaviour). Reverting b0b9d51 on today's code conflicts in 12 files | 10 / 16 | all 10 behaviour checks fail as before; the 6 retry-queue declaration checks pass, because this break keeps the queues the original revert removed |
| 20261011T160720Z-worker-negative (break named in `20261011T160720Z-notes.log`) | both `catch (OperationCanceledException) when (...)` blocks of the 3303954 shutdown fix removed | 2 / 2 | |
| 20261013T145229Z-processing-negative (break named in `20261013T145229Z-notes.log`) | implied `Processing` row written with `implied: false` | 2 / 2 | |
| 20261014T084532Z-trace-negative-no-messageid | Worker "Received StockReserved" log line without `{MessageId}` | 4 / 4 | the unbroken run first: 28/28 (`28-trace-order-clean.log`) |
| 20261014T084825Z-metrics-negative-no-duplicate-counter | `StockResultConsumer` no longer counts duplicates | 1 / 1 | |
| 20261014T105323Z-message-timestamps-negative-inventory-unstamped | Inventory `RabbitMqOutboxPublisher` sets no `Timestamp` | 5 / 5 | |
| 20261023T143020Z-reconciliation-negative-control | `ReconciliationWorker.WhereStuck` reduced to `PendingStock` | 2 / 2 | case G, as before |
| 20261023T145745Z-load-shedding-negative-inflight-off | in-flight admission check in `OrdersController` disabled | 2 / 2 | |
| 20261024T115428Z-replicas-negative-no-row-lock | Inventory Outbox claim without `FOR UPDATE SKIP LOCKED` | 2 / 2 | |
| 20261020T030230Z-validator-negative-check5 | `validate-correctness.ps1` check 5 reports PASS instead of INCONCLUSIVE | 1 / 1 | |
| 20261024T075511Z-extract-negative-old-extractor | `extract-run-metrics.ps1` from d0a947c | 14 / 9 | the same 9, plus 5 checks of features the old extractor never had (multi-replica sums, Worker dead letters) |
| 20261024T072202Z-unit-tests-negative-no-concurrency-token | `.IsConcurrencyToken()` removed from `Order.State` | 6 of 54 tests fail / 6 of 54 | the same six tests (`34-unit-no-concurrency-token.log`) |

The old extractor's "relation order_service.orders does not exist" is the intended failure, not an
environment problem: fixture i of `verify-extract.ps1` deliberately starts a PostgreSQL with no
`order_service` schema and expects the extractor to exit 2 and report the database block as
unavailable; the d0a947c extractor instead throws, so the remaining checks never run ("only 51 of 57
checks ran" now, 46 of 52 then).

## Logs that do not count, and why

- `negative/31-environment.log` (10 FAIL) and `negative/32-unit-no-concurrency-token.log`: that
  scratch clone had built only the test project, so the environment check could not run Inventory's
  migrations. The clone was then built in full (`build-unit-no-concurrency-token-solution.log`, 0
  errors), the environment passed 49/49 (`33-environment.log`) and the control was rerun:
  `34-unit-no-concurrency-token.log`.
- `progress.txt` files are the runner's own timeline. The run was interrupted once when the operator's
  session ended (after `46-load-shedding`) and resumed from `replicas` with the same numbering.

## Not re-run

- runtime-accounts (TP-E04): runs against the owner's local stack. Last: `tests/evidence/20261023T173539Z-runtime-accounts.log`.
- AWS only: TP-X01 `20261101T204940Z-ec2-pilot.log`, TP-X07 `20261104T132500Z-ec2-confirmation/summary.log`,
  TP-X02 `20261105T104832Z-official/summary.log`, TP-X13 `20261106T135523Z-supplementary/summary.log`,
  TP-X14 `20261107T060310Z-backpressure-ab/summary.log`, TP-L03 live `20261022T093449Z-ec2-deployment.log`,
  TP-L04 EC2 half `20261024T104902Z-ec2-overload.log`.
