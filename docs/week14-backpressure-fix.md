# Process Worker back-pressure fix: measurement plan

A post-freeze experiment. The official 66 runs measured the code frozen at `9d00bea`
and stay as they are. This plan measures one change to that code, the Process Worker's
back-pressure on a full queue, against the frozen code **on the same host pair in the
same session**, so the difference between host pairs (Appendix C.5 of the report)
cannot bias the comparison.

## The defect and the fix

In every official C3 and C4 overload run, a few Worker messages were dead-lettered:
2 to 27 per run.

- **Why:** when an Order Service queue reaches the C3 bound, RabbitMQ refuses the
  Worker's publish with a nack (`reject-publish`). The Worker's 1, 2 and 4 s retry
  ladder runs out while the queue is still full.
- **What it cost:** each order waited in `Confirmed` until reconciliation picked it up
  after 300 s, so most overload runs took 300 to 330 s to drain.

The fix (`src/FlashSale.ProcessWorker/Messaging/PublishBackPressure.cs`):

- **Nacks are waited out.** RabbitMQ.Client 7.1.2 reports a broker nack as a
  `PublishException` with `IsReturn = false`. The Worker treats only that as
  back-pressure and retries the same publish after 1, 2, 4 and 8 s, then every 8 s.
- **Intake stops.** The `StockReserved` message stays unacknowledged, so the Worker's
  prefetch and concurrency slots (20) fill and it stops taking new messages.
- **Waits are not failures.** They don't count as retry attempts. They are counted in
  `flashsale_consumer_backpressure_waits_total{consumer}`.
- **The cap still ends in the DLQ.** A publish still refused after 600 s
  (`Processing:BackPressureMaxWaitSeconds`) takes the normal failure path to the
  dead-letter queue.
- **Other errors are unchanged.** A return (unroutable, `IsReturn = true`) and every
  other error keep the 1, 2 and 4 s ladder and then the DLQ.

**One interaction to watch.** Reconciliation treats a `Confirmed` or `Processing` order
older than 300 s as stuck and re-publishes `OrderPlaced`, and Inventory answers with
its stored `StockReserved`. A hold longer than 300 s would therefore add a duplicate
`StockReserved`, which the Worker and Order Service's Inbox absorb. The measurement
counts reconciliation re-triggers to show whether this happens.

## Cells

| # | Config | Rate (/s) | Why |
| --- | --- | --- | --- |
| 1 | C3 | 200 | Dead letters in official runs (median 14) and drains of about 313 s |
| 2 | C3 | 400 | The heaviest shedding cell |
| 3 | C4, 1 consumer | 400 | The same cell with the C4 path |

- **Versions:** each cell runs on both versions, `frozen` (`9d00bea`) and `fix`.
- **Repeats:** 3 per version, interleaved by repeat. Repeat 1 runs every cell on
  `frozen`, then every cell on `fix`; repeats 2 and 3 do the same. Host drift over the
  session therefore affects both versions equally.
- **Total:** 18 runs.
- **Values:** every value is the frozen default (`run-matrix.ps1`, the EC2 env file,
  60 s open-loop load, stock 100,000). Only `-Configs`, `-Replicas` and `-Rates` are
  passed.

## Measures, per run

- **Worker dead letters:** `flashsale_process_worker_dead_lettered_total`. The fix
  should give 0.
- **Back-pressure waits:** `flashsale_consumer_backpressure_waits_total`. Only the fix
  exports it.
- **Reconciliation re-triggers:** `flashsale_reconciliation_retriggers_total`.
- **Drain (stable) time and 99 % done time:** as in the official analysis.
- **Completion p95:** as in the official analysis.
- **Validator:** every check must hold in every run.

## Switching versions on the backend

- **Both versions on the backend:** it holds `frozen` (`9d00bea`) and `fix` (the
  commit with the fix). Each image set is built once at deploy, under its own tag.
- **Switching:** before each run the driver points the Worker at that version's image
  and recreates only the Worker container.
- **Reset:** the run's own reset, seed and warm-up then start it clean.
- **Same code elsewhere:** Order Service and Inventory are identical in both versions,
  so they are not switched.

The exact commands are fixed once the switching step is written and checked locally.

## Time and cost

- **Runs:** C3 and C4 overload runs on the frozen code took about 6 to 8 min each,
  because of the 300 s drain. Fixed-code runs should drain in about 1 to 2 min. That is
  about 9 x 7 + 9 x 3, roughly 90 min.
- **Deploy, live check and copy-back:** about 30 + 10 + 60 min.
- **In total:** about 3 to 3.5 hours of servers. The two hosts cost about USD 0.25 an
  hour together, so the session costs under USD 1.
- **Safety timer:** `-var=auto_terminate_minutes=360`.

## What the owner does

The same steps as for the supplementary session (`docs/week14-manual-steps.md`):

- steps 2 to 8, with `-var=auto_terminate_minutes=360`;
- steps 9 and 10 when told the session is done.
