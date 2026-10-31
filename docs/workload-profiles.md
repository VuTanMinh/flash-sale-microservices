# Workload profiles (Week 13, TP-X04)

Every brief §6 workload profile is one parameterisation of
`tests/jmeter/workload.jmx` — a single open-loop plan (built-in elements only, no
plugins/JSR223, so it runs on Java 25) that POSTs `/api/orders` (or
`/api/c1/orders`) with a fresh `Idempotency-Key`, then polls accepted orders to a
terminal state. Product ids come from a CSV Data Set (`-JproductsFile`, recycle
on, all threads). Five stages run one after another; stage `N` has
`threadsN`/`rateN` (per second)/`durationN` (seconds), and a stage with
`threadsN=0` is skipped (set its `durationN=0` too so it adds no delay). Stage 1
also takes `loops1` (default `-1` = run for `duration1`); a positive `loops1`
runs exactly that many iterations per thread, which is how the exact request
volume below is produced.

Before every run, reset + seed + warm up (`docs/deployment.md` §10), and run
`scripts/validate-correctness.ps1` after it.

## Coverage

| Brief §6 profile | plan | exact `-J` parameters | seed |
|---|---|---|---|
| steady load | stage 1 only | `threads1=<n> rate1=<r> duration1=<d>`, others 0 | one product, stock ≥ offered volume |
| ramp-up | stages 1→2→3 rising | `rate1<rate2<rate3` (threads rising too) | one product, stock ≥ offered volume |
| spike (low/high/low) | stages 1→2→3 | `rate1=low rate2=high rate3=low` | one product, stock ≥ offered volume |
| sustained overload + recovery | stages 1→2→3 | `rate1=baseline rate2=overload rate3=recovery` | one product, stock large |
| one hot product | any single stage, `products-hot.csv` | `-JproductsFile=products-hot.csv` | one product, stock large |
| skewed demand | any single stage, `products-skewed.csv` | `-JproductsFile=products-skewed.csv` | 4 products 70/15/10/5, stock large |
| below / equal / above inventory | stage 1 with `loops1` | `threads1=5 loops1=N/5 duration1=600` (exact total `5×(N/5)=N`), others 0 | one product, stock `S`; run `N<S`, `N=S`, `N>S` |

## Commands

One product per run unless stated. `path` is `/api/orders` for C2/C3/C4 and
`/api/c1/orders` for the C1 baseline (the plan skips polling automatically on
`/api/c1/orders`, whose response has no order id). Run the commands from the repo
root (`cd /opt/flash-sale-microservices`); the `pwsh -NoProfile -Command "&
./scripts/..."` forms below use repo-relative paths because a hashtable
(`-Products`/`-StableRange`) cannot be passed through `pwsh -File`.

```bash
# steady — 50/s for 60 s
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jthreads1=100 -Jrate1=50 -Jduration1=60 \
  -Jthreads2=0 -Jduration2=0 -Jthreads3=0 -Jduration3=0 -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/steady.jtl -j /tmp/steady.log

# ramp-up — 10 / 30 / 60 r/s, 30 s each
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jthreads1=40 -Jrate1=10 -Jduration1=30 \
  -Jthreads2=80 -Jrate2=30 -Jduration2=30 \
  -Jthreads3=120 -Jrate3=60 -Jduration3=30 \
  -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/ramp.jtl -j /tmp/ramp.log

# spike — 5 / 100 / 5 r/s, 30 s each
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jthreads1=40 -Jrate1=5 -Jduration1=30 \
  -Jthreads2=160 -Jrate2=100 -Jduration2=30 \
  -Jthreads3=40 -Jrate3=5 -Jduration3=30 \
  -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/spike.jtl -j /tmp/spike.log

# sustained overload + recovery — 3 / 60 / 3 r/s
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products.csv \
  -Jthreads1=40 -Jrate1=3 -Jduration1=30 \
  -Jthreads2=120 -Jrate2=60 -Jduration2=60 \
  -Jthreads3=40 -Jrate3=3 -Jduration3=60 \
  -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/overload.jtl -j /tmp/overload.log

# one hot product — steady, single product CSV
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products-hot.csv \
  -Jthreads1=100 -Jrate1=50 -Jduration1=60 \
  -Jthreads2=0 -Jduration2=0 -Jthreads3=0 -Jduration3=0 -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/hot.jtl -j /tmp/hot.log

# skewed — steady, products-skewed.csv (flash-product-1..4, 70/15/10/5 %)
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products-skewed.csv \
  -Jthreads1=100 -Jrate1=50 -Jduration1=60 \
  -Jthreads2=0 -Jduration2=0 -Jthreads3=0 -Jduration3=0 -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/skewed.jtl -j /tmp/skewed.log

# below / equal / above inventory — exact total = threads1 x loops1 (one product, stock S)
#   seed with stock S, then run three times: N<S, N=S, N>S. Run from the repo root
#   (/opt/flash-sale-microservices), so the scripts use repo-relative paths.
pwsh -NoProfile -Command "& ./scripts/reset-and-seed.ps1 -Container infra-postgres-1 -Full -RedisContainer infra-redis-1 -RabbitMqContainer infra-rabbitmq-1 -Products @{ 'flash-product-1' = 20 }"
pwsh -NoProfile -Command "& ./scripts/warm-up.ps1 -Container infra-redis-1 -Products @{ 'flash-product-1' = 20 } -Force"
/opt/jmeter/bin/jmeter -n -t tests/jmeter/workload.jmx \
  -Jhost=<backend-ip> -Jport=80 -Jpath=/api/orders -JproductsFile=products-hot.csv \
  -Jthreads1=5 -Jrate1=1000 -Jduration1=600 -Jloops1=2 \
  -Jthreads2=0 -Jduration2=0 -Jthreads3=0 -Jduration3=0 -Jthreads4=0 -Jduration4=0 -Jthreads5=0 -Jduration5=0 \
  -Jsample_variables=idempotencyKey -l /tmp/below.jtl -j /tmp/below.log
pwsh -File scripts/validate-correctness.ps1 -Config C4 -ProductId flash-product-1 -InitialStock 20 \
  -PgContainer infra-postgres-1 -RedisContainer infra-redis-1
```

For the below/equal/above profile the validator must report successful
reservations = `min(N, S)` (and stock conserved). Use `threads1=5` and
`loops1=N/5` so the exact total is `5 × (N/5) = N` (e.g. `N=10` → `loops1=2`,
`N=20` → `loops1=4`, `N=30` → `loops1=6`). `duration1` must be LONG enough for
`threads1 × loops1` iterations to finish: JMeter silently stops a thread group at
its duration, so a short duration cuts the loop short and drops submissions (with
`threads1=1` and ~3 s of polling per iteration, `duration1=60` dropped the tail
of a 30-request run). Use `duration1=600` (or more) so the scheduler never
truncates the loop, and set `rate1` high (e.g. 1000) so the Constant Throughput
Timer never throttles it.

## What the plan cannot do

- **Product affinity is by CSV only.** All threads share one recycled CSV cursor,
  so "one hot product" and "skewed demand" are expressed as the *contents* of the
  CSV (one row, or 20 rows at 70/15/10/5), not as a per-thread assignment. A
  per-thread product would need JSR223, which Java 25 forbids here.
- **Polling is bounded** (40 polls ≈ 20 s). An order that has not reached a
  terminal state in that window is no longer polled; its POST is still counted,
  but the end-to-end completion latency for that order is not observed.
- **`rateN` is a ceiling, not the offered load (measured).** Each thread polls its
  accepted order to a terminal state before it submits again, so the plan is
  closed-loop: once polling takes longer than the rate allows, the submit rate
  falls to the downstream completion rate. The Worker's defaults (200 ms, one at a
  time) complete 5 orders/s, and the clean-clone run
  (`tests/evidence/20261031T161516Z-ec2-stack.log`, commit a791d71, local Docker)
  achieved 5.6-5.7 submissions/s at `rate1=50 threads1=50`, with 1, 2 and 4
  replicas alike, and 4.5/s at `rate1=10 threads1=20`. The same `rate1=10
  threads1=20` on `/api/c1/orders`, which does not poll, achieved 11.1/s. Read the
  achieved rate from the JTL and report that number, never `rateN`. To reach a
  rate, either raise `threadsN` to about `rateN` × the seconds an order takes to
  finish (up to the 20 s polling bound, so 50/s can need 1000 threads), or raise
  `PROCESSING_MAX_CONCURRENCY`. The thread counts in the commands above were not
  sized this way.
- **Exact volume is stage-1 only.** Only stage 1 has `loops1`; a fixed total for
  multi-stage profiles is not expressed directly (use rate × duration instead).
- **No per-phase JMeter dashboard inside the plan.** Samplers are labelled
  `submit-stageN`/`poll-stageN`, so per-phase numbers come from
  `scripts/extract-run-metrics.ps1` (or JMeter's `-g` dashboard), not from the
  plan itself.
