# Full regression of the pushed code (88be225), 14 November 2026

Verification only: no service code, configuration, test or report changed. Every Docker check ran on
throwaway containers (verifier PostgreSQL `verify-env-pg` on port 56432, rebuilt fresh before each
database check; each verifier's own RabbitMQ and Redis), never on the owner's local stack.
Builds and runs used clean copies of 88be225 on E: (D: carries a low-integrity label).

## Results that count

| Check | Result | Log |
|---|---|---|
| Build, solution + Process Worker tests + probes, Debug and Release | 0 warnings, 0 errors | `build-*.log` |
| Unit tests, Order Service, with PostgreSQL race tests | 104/104 | `64-unit-postgres.log`, `.trx` |
| Unit tests, Process Worker | 7/7 | `unit-FlashSale.ProcessWorker.Tests.log` |
| design-chapter, test-plan, freeze, design-alignment, design-decisions, requirements-trace, observability-report, workflow (static), baseline/order/publication/inventory/delivery/failure-report | all PASS | `<name>.log`, `summary-static.txt` |
| failure-report -SelfTest (one changed number must be caught) | SELFTEST PASS | `failure-report-negative.log` |
| environment (49 checks, before every database check) | PASS every time | `NN-environment.log` |
| erd 32, reset-seed 8, validator 28, real-runs 7, workflow live 66, outbox 12, publication 18, inventory 36, cross-store 11, stock-results 10, db-exceptions 7, delivery 41, delivery-ordering 44, failures 74, reconciliation 35, processing 41, worker 56, metrics 17, message-timestamps 40, extract 57, load-shedding 45, replicas 5 | all PASS, 0 FAIL | `02-...` to `48-...` |
| delivery -NegativeControlForgetReservation | fails 3 checks, as designed (the "exactly 1 unit" checks) | `26-delivery-negative.log` |
| run-collector (from a git clone) | 30/30 | `52-run-collector.log` |
| write-failures | 40/40 | `58-write-failures.log` |
| deployment (offline + 3 image builds; 2 live parts SKIP, need the AWS JMeter host) | 25/25 | `59-deployment.log` |
| ec2-stack (local, own Compose project) | 89/89 | `60-ec2-stack.log` |
| order-api (Order Service on 5100, pool 60 as configured, broker unreachable) | 30/30; the service log showed 0 HTTP 500 responses | `67-order-api.log` |

## Logs that do not count, and why (not committed)

These logs were kept out of the repository; the reasons are recorded here. The two Order Service
stdout logs (`62-`, `66-order-api-service.log`, about 2.4 MB each, mostly the expected broker
reconnect messages) and the first static `deployment.log` (run while Docker was off, so its 3 image
builds failed; rerun as `59-deployment.log`) are also not committed.


- `42-run-collector.log` (1 FAIL): run from a `git archive` copy with no git history, so the
  collector recorded commit "unknown"; rerun from a git clone: `52-run-collector.log` 30/30.
- `50-write-failures.log`, `51-deployment.log`, `52-ec2-stack.log`, `54-write-failures.log`,
  `55-deployment.log`, `56-ec2-stack.log`: the first runner, believed stopped when a session ended,
  kept running alongside the resumed one; both used the same containers and ports. Reruns one at a
  time: `58`, `59`, `60`. `51`/`55-deployment` also ran from a copy without Terraform's initialised
  folder (`terraform validate` asks for `init`); `59` ran from the repository.
- `63-order-api.log` (1 FAIL, one HTTP 500 out of 200): the Order Service was started with a
  connection string without the `Maximum Pool Size=60` that appsettings.json and the EC2 Compose file
  set, so PostgreSQL ran out of connections (53300). Rerun with the configured cap: `67-order-api.log` 30/30.

## Not re-run

- runtime-accounts (TP-E04): runs against the owner's local stack. Last: `tests/evidence/20261023T173539Z-runtime-accounts.log`.
- AWS only: TP-X01 `20261101T204940Z-ec2-pilot.log`, TP-X07 `20261104T132500Z-ec2-confirmation/summary.log`,
  TP-X02 `20261105T104832Z-official/summary.log`, TP-X13 `20261106T135523Z-supplementary/summary.log`,
  TP-X14 `20261107T060310Z-backpressure-ab/summary.log`, TP-L03 live `20261022T093449Z-ec2-deployment.log`,
  TP-L04 EC2 half `20261024T104902Z-ec2-overload.log`.

## Code review (read-only)

One low-severity defect, left as is by the owner's decision (option A, Week 15 allows no source
changes): Inventory's OrderPlacedProcessor runs reserve.lua before looking for a stored result, so an
order rejected with NOT_OPEN before warm-up, not applied within the reconciliation timeout and
re-triggered after the sale opens, ends Rejected while Redis holds one unit for it. It cannot occur
when warm-up precedes orders, never oversells, and the validator flags the mismatch.
