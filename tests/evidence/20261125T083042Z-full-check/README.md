# Full project check after the 25 November code fixes

Regression and negative controls for the code changes of 25 November 2026, before the
code lock of 27 November. Run on a fresh clone on E: (`E:\Agent_Memory\DACNTT\fullcheck-20261125T083042Z`),
because builds on D: run at low integrity; logs are written here.

## Code under test

| Commit | Change |
|---|---|
| `1850b0f` | Process Worker host `ShutdownTimeout` 15 s (case E1 of `verify-worker.ps1`) |
| `042e853` | OpenIddict certificate passphrase read from `AuthServer:CertificatePassPhrase` |
| `e4375f5` | Inventory looks up the stored result before `reserve.lua` (closes the NOT_OPEN undersell gap); new `tests/FlashSale.InventoryService.Tests` |
| `13f5973` | GitHub Actions workflow (not yet run on GitHub: nothing is pushed) |
| `cbc3f59` | Docs follow the Inventory fix |
| `4fb353f` | `verify-workflow.ps1` follows the Inventory fix (see "Stop and restart") |

## Stop and restart

The run started at 08:30 UTC on `cbc3f59`. At 08:41 `verify-workflow.ps1` failed one
static code check twice (65/66, `10-workflow.log`, `12-workflow.log`), and the runner stopped
as designed. The check required exactly one `SaveChangesAsync(` in `OrderPlacedProcessor`,
written after the Outbox and Inbox writes; the injectable-save overload added in `e4375f5`
(same pattern as `StockResultProcessor`) puts a `() => dbContext.SaveChangesAsync()` at the top
of the file. Behaviour was unchanged. The check was updated in `4fb353f`: the save point is
`await saveChangesAsync()`, the production overload must pass the real `SaveChangesAsync`, and
the stored-result lookup must come before `ReserveAsync` (this condition fails on the code
before `e4375f5`). The clone was fast-forwarded to `4fb353f` and the run resumed at the
workflow step at 10:47 UTC (`progress.txt`). The static pass ran on `cbc3f59`; its workflow
check was rerun on `4fb353f` as `static/17-workflow.log`.

## Results

**Builds** (Debug and Release, solution plus ProcessWorker tests, BrokerProbe, InventoryProbe): 0 errors.

**Static verifiers** (`static/summary.txt`): all pass. `08-workflow` (37/38, on `cbc3f59`) is
superseded by `17-workflow` (38/38, on `4fb353f`). `15-failure-report-negative` is that
verifier's own self-test and must report one FAIL (it does).

**Runtime verifiers** (`summary.txt`), each after a fresh throwaway PostgreSQL (`environment`, 49/49 every time):

| Verifier | PASS | FAIL |
|---|---|---|
| erd | 32 | 0 |
| reset-seed | 8 | 0 |
| validator | 28 | 0 |
| real-runs | 7 | 0 |
| workflow (after restart) | 66 | 0 |
| outbox | 12 | 0 |
| publication | 18 | 0 |
| inventory | 36 | 0 |
| cross-store (crash retry still gets DUPLICATE from Redis) | 11 | 0 |
| stock-results | 10 | 0 |
| db-exceptions | 7 | 0 |
| delivery | 41 | 0 |
| delivery -NegativeControlForgetReservation | 38 | 3 (expected) |
| delivery-ordering | 44 | 0 |
| failures | 74 | 0 |
| reconciliation | 35 | 0 |
| processing | 41 | 0 |
| worker (includes E1, the shutdown fix) | 56 | 0 |
| metrics | 17 | 0 |
| message-timestamps | 40 | 0 |
| extract | 57 | 0 |
| load-shedding | 45 | 0 |
| replicas | 5 | 0 |
| run-collector | 30 | 0 |
| write-failures | 40 | 0 |
| ec2-stack (production image; passphrase from configuration) | 89 | 0 |
| order-api (Order Service on 5100, broker unreachable) | 30 | 0 (0 HTTP 500 lines) |

**Unit tests**: InventoryService 3/3; OrderService 104/104 including the 6 PostgreSQL race
tests (`FLASHSALE_TEST_PG` set to the throwaway database); ProcessWorker 7/7.

## Negative controls (`negative/`)

`neg-check.ps1` recreates each committed negative control's break in a scratch clone and runs
its verifier. It ran twice: 08:42–09:58 on `cbc3f59` (after the first stop) and 12:41–14:12 on
`4fb353f`. Both passes gave the same result; the log files in `negative/` are from the second
pass (same names), and `negative/progress.txt` keeps both. Every break was detected:

| Break | Verifier | FAIL |
|---|---|---|
| workflow-no-queue | workflow | 7 |
| delivery-no-inbox-check | delivery | 1 |
| delivery-ack-before-commit | delivery | 12 |
| delivery-ordering-early-completion-dead-lettered | delivery-ordering | 10 |
| worker-shutdown-fix-reverted | worker | 2 |
| processing-implied-false | processing | 2 |
| metrics-no-duplicate-counter | metrics | 1 |
| message-timestamps-inventory-unstamped | message-timestamps | 5 |
| reconciliation-pendingstock-only | reconciliation | 2 |
| load-shedding-inflight-off | load-shedding | 2 |
| replicas-no-row-lock | replicas | 2 |
| validator-check5-pass | validator | 1 |
| extract-old-extractor | extract | 14 |
| trace-order no-messageid (clean run 28/0) | trace-order | 4 |
| unit-no-concurrency-token | OrderService unit tests | 6 of 54 |

**Negative control for the Inventory fix (`e4375f5`)**, run by hand on 25 November in a
scratch copy (`E:\Agent_Memory\DACNTT\negfix2`), not in this folder: the old order was put back
by inserting `await reservationService.ReserveAsync(...)` before the stored-result lookup. Then
`tests/FlashSale.InventoryService.Tests` gave 2 failed / 1 passed; both failures were
`InvalidOperationException: Redis must not be used in this test.` (the two stored-result tests;
the Inbox test stays green, as expected). With the fix, 3/3 pass.

## Not covered here

- The GitHub Actions workflow is proven only after a push. Its commands were run locally on a
  fresh copy (Release build 0 warnings/0 errors; unit tests as above; the race tests against a
  throwaway `postgres:16` container, 6/6).
- No new EC2 run: the official results (tag `w14-official`) were measured on the code before
  these changes and are not re-measured. The Inventory change only alters what happens to an
  `OrderPlaced` for an order that already has a stored result (a re-trigger or replay); the
  first reservation of every order runs exactly as before.
