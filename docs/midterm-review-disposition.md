# Midterm review: finding disposition (Weeks 1–12)

Reviewed commit: `cf9c65d`. Branch tip when this pass started: `main-test-bug-fix`
at `d0a947c` (one commit after the review: the first round of fixes). This pass
was developed on `week1-2` and copied to the review branch
`midterm-review-repairs` (cut from `d0a947c`).

Status words:

- **already fixed**: fixed in `d0a947c`, re-checked in this pass;
- **confirmed → fixed**: the defect was reproduced or read in the code, then fixed with a test;
- **partly open**: fixed as far as the evidence allows, and the open part is named;
- **disproved**: the suspected defect does not exist (none in this pass).

Every log path is under `tests/evidence/`. The verifier header in `scripts/` lists
each check.

| # | Finding | Status | What the code does now | Evidence |
|---|---|---|---|---|
| A | Start handler can save `Processing` over a committed `Completed` | already fixed (d0a947c); confirmed on PostgreSQL in this pass | `Order.State` is an EF concurrency token (`src/FlashSale.OrderService/Data/OrderServiceDbContext.cs`); on a conflict `StockResultProcessor.RetryOnStateConflictAsync` clears the tracker and re-decides from a fresh read (`src/FlashSale.OrderService/Messaging/StockResultProcessor.cs`); state, history and Inbox are saved in one `SaveChanges` | `OrderStateRacePostgresTests` (new): two connections and barriers on real PostgreSQL. Covers both save orders, duplicate starts, conflicting stock results, `Completed` never regressing, and ABP's exception type. Unit tests 104/104 `20261024T084347Z-unit-tests.log`; negative control without the token: 6 tests fail (4 PostgreSQL race tests, 2 SQLite late-start tests) `20261024T072202Z-unit-tests-negative-no-concurrency-token.log` |
| B | No consumer prefetch; queue bound misses unacked work (252 vs 5) | already fixed (d0a947c) | `BasicQosAsync(prefetch 20)` in all five consumers; the collector and extractor count ready + unacknowledged; in-flight admission bound counts unfinished orders (`InFlightOrdersMonitor`) | TP-L04 case H/I `20261024T080008Z-load-shedding.log`; negative control with the in-flight bound off `20261023T145745Z-load-shedding-negative-inflight-off.log`; bounds and overshoot in `docs/load-shedding.md` |
| C | Recovery reported for an all-503 run | already fixed (d0a947c); extended in this pass | recovery = first sustained window after overload removal with p95 of **accepted** responses, error, refusal and throughput limits, and optional total-backlog limit; no 1-s gap in the window; missing series never 0 | `verify-extract.ps1` fixtures: all-503, all-429, low throughput, slow 2xx hidden by fast refusals, a gap, missing samples `20261024T073819Z-extract.log` (negative: `20261024T075511Z-extract-negative-old-extractor.log`) |
| D | 773 accepted vs 771 in summary | already fixed (d0a947c) | run membership by the JTL's Idempotency-Keys; one interval row per order, original publish time kept when reconciliation re-publishes | `verify-extract.ps1` membership, boundary-request and cohort-count fixtures `20261024T073819Z-extract.log` (negative: `20261024T075511Z-extract-negative-old-extractor.log`) |
| E | SQL errors read as 0 | already fixed (d0a947c); extended in this pass | `Sql` throws on a non-zero exit; numeric results go through `SqlInt` (exactly one integer line); a query failing after the probe makes the database block, drain and recovery `unavailable` and exits 2 | fixture (i): a database without the schema `20261024T073819Z-extract.log` (negative: `20261024T075511Z-extract-negative-old-extractor.log`) |
| F | Reconciliation only scanned `PendingStock` | already fixed (d0a947c); procedure extended | `Confirmed`/`Processing` past `ProcessingStuckTimeoutSeconds` (300 s) are re-triggered, bounded, with a gauge and a give-up alert; Worker-side DLQ redrive documented | TP-F02 case G `20261024T075611Z-reconciliation.log`; DLQ procedure in `docs/failure-handling.md` |
| G1 | `set-queue-bounds.ps1` needs a published 15672 and dev credentials | confirmed → fixed | without a 15672 mapping it uses `rabbitmqctl` inside the container (no port, no password); `-Inspect` lists policies and queue depths | `verify-run-collector.ps1` container-mode cases `20261024T074956Z-run-collector.log` (26/26; negative: `20261024T075235Z-run-collector-negative-old-scripts.log`) |
| G2 | Collector needs the management port and a password on EC2 | confirmed → fixed | `-RabbitMqContainer` reads queues with `rabbitmqctl`; rates recorded `unavailable` with the reason; password from `RABBITMQ_PASSWORD`, never written | same log |
| G3 | (found in this pass) EC2 Worker metrics unreachable | confirmed → fixed | `appsettings.json` `Urls` overrode `ASPNETCORE_URLS`, so the container listened on loopback 5100 (`20261022T163505Z-ec2-overload.log`: "process-worker : Connection refused (172.18.0.7:8080)"). `infra/docker-compose.ec2.yml` now sets `Urls: http://+:8080` | reproduced and fixed locally (the Worker exe with only `ASPNETCORE_URLS` listened on 127.0.0.1:5100; with `Urls` on :::port); confirmed on EC2 on 2026-10-24: `/metrics` 200, all four Prometheus targets up, 24 Worker rows in the first collector sample `20261024T104902Z-ec2-overload.log` |
| H | `docs/` and `report/` missing; README; EC2 raw artifacts | confirmed → fixed (old raw data not recoverable) | `docs/` restored on the review branch; README links fixed; `docs/reproduction.md` and `docs/evidence-index.md` added; local overload raw data archived (JTL, samples, stage intervals, summary) | The 22 Oct EC2 run's raw data stays lost (not reconstructed). It is replaced by an EC2 rerun on the reviewed code on 2026-10-24 whose raw JTL, samples, stage intervals and summary are archived (`20261024T104902Z-ec2-overload-*`; every refused key checked) |
| I | Progress-report claims | confirmed → fixed | report source updated: claims restated, latency split by outcome, sections for assessed commit, settings, requirements map, limitations | `report/progress/progress-report.tex`; latency split computed by `report/figures/latency_split.py` from archived raw files |
| J | Outbox 50 rows / 2 s; serial Worker; C4 interpretation | confirmed → fixed / documented | Outbox drains full batches back to back on one channel with batched confirms; Worker concurrency is a setting (default 1); C4 caveat written in the report | `verify-outbox.ps1` 300-row drain `20261024T083744Z-outbox.log`; `verify-worker.ps1` case H `20261024T083825Z-worker.log` |
| K | (found in this pass) crash between Redis reservation and PostgreSQL save untested | confirmed → tested | `FaultInjection.CrashAfterReserveIfTargeted` kills Inventory after Lua and before the save | `verify-delivery.ps1` case 1b `20261024T083445Z-delivery.log` (41/41); negative control (Redis record erased → second deduction) `20261024T064020Z-delivery-negative-forget-reservation.log` |
| L | (found in this pass) "Reconciliation off" in verifiers still fired on orders older than 1 h in the shared database | confirmed → fixed | `Reconciliation:Enabled` (default true); 17 verifiers set it false instead of a 3600-s timeout | the polluted run (6 dead-lettered `StockRejected`) was diagnosed in this pass; reruns clean |

## Unexecuted checks

- EC2 (2026-10-24, after the push of `45486aa`): G1–G3 confirmed live and the
  overload run repeated with raw data archived. Not repeated on EC2: the local
  verifiers themselves (they are local by design).
- The verifiers ran on Windows PowerShell 5.1 only; PowerShell 7 on Linux was not run.
- The repeated experiments (TP-X01, TP-X02) and the README reproduction on a
  fresh machine (TP-X03) belong to Weeks 13–14.

## Added after the second pass (2026-10-24 afternoon)

| # | Finding | Status | What the code does now | Evidence |
|---|---|---|---|---|
| M | (found in review) Inventory replicas publish every Outbox row once per replica, so C4 would measure duplication | confirmed → fixed | both publishers claim their batch with `FOR UPDATE SKIP LOCKED` inside a transaction | `verify-replicas.ps1` (TP-L05): 400 rows → 400 messages with 2 and 4 replicas `20261024T115610Z-replicas-2.log`, `20261024T115644Z-replicas-4.log`; without the lock 800 `20261024T115428Z-replicas-negative-no-row-lock.log` |
| N | No research-question data at midterm | partly addressed | first local C1-vs-C2 pilot at 50 and 200 requests/s, validator PASS in all four runs; C2's stock path is limited by one sequential Inventory consumer (~71 decisions/s on the PC) | `20261024T112852Z-pilot-c1-c2-50rps-*`, `20261024T113202Z-pilot-c1-c2-200rps-*`. **Open:** EC2 capacity matrix (C1, C2, C4, Inventory in-process concurrency) at equal offered loads |
