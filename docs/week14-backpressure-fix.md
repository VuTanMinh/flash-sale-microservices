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

The session driver is `scripts/ec2-session.ps1 -Plan backpressure`, with its helpers
`scripts/ec2-ssm-run.ps1` and `scripts/ec2-ssm-file.ps1`. It copies itself and both
helpers into the session's evidence folder when it starts.

- **One build, two Worker images.** The deploy builds every image from the branch
  head (`035e599`), so the Worker image is the fix. Once per session the driver tags
  that image `flashsale-process-worker:fix`. It also builds the Worker from the tag
  `w14-official` (`9d00bea`, in a git worktree at `/opt/w14-official`) as
  `flashsale-process-worker:frozen`.
- **Order Service and Inventory are not switched.** They are byte-identical between
  the two commits: `git diff w14-official 035e599` changes only the Process Worker,
  report verifiers and docs.
- **The switch.** Before each run the driver re-points the tag the compose file
  names at that run's image, then recreates only the Worker:

  ```
  docker tag flashsale-process-worker:<v> flashsale-process-worker:10.0
  docker compose --env-file infra/ec2.env -f infra/docker-compose.ec2.yml up -d --no-deps process-worker
  ```

  It then waits until `ProcessWorker.StockReserved` has a consumer. The run's own
  `compose up` in `run-matrix.ps1` finds the Worker already on that image and leaves
  it.
- **Why not a compose override.** `run-matrix.ps1` passes `-ExtraComposeFile` to
  Local runs only, so over SSM its `compose up` would put the Worker back on the
  deployed image. The first switch check on EC2 caught this: the frozen check run's
  manifest recorded the fix image. That check run is discarded.
- **The reset.** The run's own reset, seed and warm-up then start it clean.
- **What each run records.** `official.json` records `worker_version` and
  `worker_image`. `manifest.json` records every container's image id. `host-post.log`
  records reconciliation re-triggers by state, from Order Service's log.
- **The switch check, before any measured run.** On the backend, the driver switches to
  frozen and then to fix, and runs a short C3 at 5/s for 20 s on each. The check
  passes when:
  - the image id changes between the two;
  - the validator passes on both;
  - `flashsale_consumer_backpressure_waits_total` is exported only by the fix.
  A local run of the same check could not be done, because Docker was not running on
  the PC.

The command, after the owner's apply and the deploy:

```
powershell -ExecutionPolicy Bypass -File .\scripts\ec2-session.ps1 -Plan backpressure `
  -Backend <i-backend> -JMeter <i-jmeter> -BackendIp <backend-private-ip> `
  -TimerEndUtc <apply time + 360 min> -Out <session folder>
```

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
