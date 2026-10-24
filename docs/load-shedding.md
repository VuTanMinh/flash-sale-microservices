# Load shedding (Week 12 box 1, C3)

C3 adds three overload layers so a flash-sale can shed excess load **early**,
before it reaches the parts that cost real work (a database write, a Redis
reservation, a downstream publish). Each layer rejects at a different edge of
the system, with its own response and its own counter, and every layer is
**off by default** so C2's behaviour is byte-for-byte unchanged until a C3
configuration turns the layers on.

| Layer | Where it sits | What is refused | Client sees | Counted where |
|---|---|---|---|---|
| 1. Gateway rate limit | Nginx in front of Order Service | `POST /api/orders` over `ORDER_RATE` | HTTP **429** | Nginx access log `$status` |
| 2. Application admission | `OrdersController.CreateOrderAsync`, before the order is added | A brand-new order when the concurrency gate is full | HTTP **503** + `Retry-After: 1` | `flashsale_admission_rejected_total{reason="concurrency"}` |
| 2b. Outbox-backlog admission | `OrdersController.CreateOrderAsync`, after idempotency, before the concurrency gate | A brand-new order when the Outbox already holds `MaxOutboxBacklog` unpublished rows | HTTP **503** + `Retry-After: 1` | `flashsale_admission_rejected_total{reason="backlog"}` |
| 2c. In-flight admission | `OrdersController.CreateOrderAsync`, after the backlog check, before the concurrency gate | A brand-new order when `MaxInFlightOrders` orders are still unfinished (not `Completed` or `Rejected`) | HTTP **503** + `Retry-After: 1` | `flashsale_admission_rejected_total{reason="inflight"}` |
| 3. Bounded queues | A RabbitMQ policy on the six main input queues | A publish to a queue already at `max-length` | broker **nack** (publisher sees it, client still 201) | `flashsale_outbox_unpublished` (the row stays unpublished) |

The three layers are deliberately ordered: a request is shed at the *first*
layer whose limit it exceeds, and never reaches the ones behind it. A request
that the gateway lets through may still be refused by admission — the backlog
bound first, then the concurrency gate, both inside Layer 2 — and a request that
passes both may still have its `OrderPlaced` event nacked at a full queue — but
its order was already accepted, so the client's 201 is correct and the event is
retried from the Outbox.

## Why these three, and the teacher brief

Brief §4 asks for "rate limiting tại Nginx, concurrency limiting tại
application và bounded queue tại RabbitMQ", and for a new request to be
"rejected sớm bằng response code phù hợp" (rejected early with an appropriate
response code). The three layers map one-to-one onto those three limits, and
the two HTTP-facing layers each reject with the code that means "too busy,
try again" — 429 (Too Many Requests) at the gateway and 503 (Service
Unavailable) at the application.

Admission rejections are counted **separately from failures** (the study guide
requirement): `flashsale_admission_rejected_total` is a counter of its own, not
a 5xx in the generic error bucket, so Week 13/14 can read "shed vs. failed" as
a ratio instead of conflating the two.

## Layer 1 — Nginx gateway rate limit

`infra/nginx.conf` is a reverse proxy to Order Service. It is mounted into the
official image's `/etc/nginx/templates/default.conf.template`, so the image's
entrypoint expands the `${ORDER_UPSTREAM}`, `${ORDER_SCHEME}`, `${ORDER_RATE}`
and `${ORDER_BURST}` placeholders from the environment before nginx starts
(`infra/docker-compose.yml` sets the defaults and adds
`host.docker.internal:host-gateway`).

**Upstream scheme (R1 choice).** `proxy_pass ${ORDER_SCHEME}://${ORDER_UPSTREAM}`
with `proxy_ssl_verify off;` (a no-op for `http`, required for Order Service's
self-signed `https` dev cert). The compose default is `ORDER_SCHEME: https` +
`ORDER_UPSTREAM: host.docker.internal:44314`, because 44314 is the only port
Order Service actually listens on. The C3 verifier overrides both to
`ORDER_SCHEME=http` + its throwaway HTTP Order Service port, which is the path
that is actually exercised by the test.

- `limit_req_zone $order_post_key zone=order_post_limit:10m rate=${ORDER_RATE}`
  with a `map` on `"$request_method:$uri"` that yields `""` for every request
  except `POST /api/orders` — matched case-insensitively and with one optional
  trailing slash (`~*^POST:/api/orders/?$`), because ASP.NET routing is
  case-insensitive and ignores a trailing slash. nginx's `limit_req` skips
  requests whose key is empty, so **GET polling is never limited**, not merely
  "limited more slowly".
- A wrong-case `POST /API/orders` does not match `location = /api/orders` or
  `location /api/orders/` (nginx location matching is case-sensitive), so the
  catch-all `location /` answers it with 404 in the rewrite phase — before
  `limit_req` runs. It is still refused (never proxied to Order Service), just
  with 404 instead of 429. `POST /api/orders/` (trailing slash) still reaches
  the limited location and gets 429.
- **The limit key is per source IP, not one global key.** `$order_post_key` is
  `$binary_remote_addr` for the limited POSTs, so each client IP gets its own
  bucket. The brief says "one global key"; per-IP is acceptable here because
  JMeter drives the load from a single machine (one IP ⇒ one bucket). Behind a
  load balancer the buckets would instead be keyed by the LB's own IP, so every
  client would share one bucket — worth remembering for the Week 13 pilot's
  topology.
- `limit_req zone=order_post_limit burst=${ORDER_BURST} nodelay;` and
  `limit_req_status 429` are set at **server** level, so no location can skip
  the limit; the map decides which requests actually share the bucket.
  `ORDER_BURST` must be ≥ 1 (`burst=0` is invalid nginx syntax); the verifier's
  case A uses `1`, the smallest valid burst.
- The exact `location = /api/orders` still exists purely to stop the
  trailing-slash `location /api/orders/` from 301-redirecting the slash-less
  `/api/orders` to `/api/orders/` (the R6 property). `location /api/orders/`
  (the `GET /api/orders/{id}` poll) and `location = /nginx-health` pass through
  with no per-location `limit_req`; the catch-all `location /` returns 404 so
  nothing else (swagger, the ABP admin UI, identity, `/metrics`) is proxied
  through the gateway.
- The combined access log records `$status`, so the verifier can count 429s.

There is no `limit_conn` here: application concurrency is limited in the app
(Layer 2), not by connection count.

## Layer 2 — Order Service admission

`AdmissionOptions` (`Admission:Enabled`, default `false`;
`Admission:MaxConcurrentNewOrders`, default `64`) and a singleton
`OrderAdmissionGate` built on `SemaphoreSlim`. `TryEnter` waits zero: a
brand-new order is either admitted now or refused with **503**, it never queues
behind the limit.

In `CreateOrderAsync` the admission check sits **after** the idempotency lookup
and **before** any database write:

- a retry of an already-accepted order (same `Idempotency-Key` + payload) is
  answered from the existing row — the unchanged 200 replay or 409 conflict
  path — **without ever touching the gate** (owner decision: an accepted order
  always gets its original order back, even when admission is full);
- a brand-new order that finds the gate full gets **503** with
  `Retry-After: 1`, increments `flashsale_admission_rejected_total{reason="concurrency"}`
  and touches nothing in the database (no order, no Outbox row);
- the slot is released in a `finally` after `SaveChangesAsync`, so it is also
  released on the unique-violation race path and on any exception.

The counter is registered with a zero `reason="concurrency"` series at startup
(`OrderMetrics.Initialize()`, called from `Program.cs`), matching how the Week
11 metrics pre-create their labelled series.

`FaultInjection:AdmissionHoldMilliseconds` is a **test-only** hook (off by
default, never present in any `appsettings*.json`, same pattern as
`CrashBeforeAck*`): when set, an admitted request holds its slot for that many
milliseconds so a test can saturate the gate deterministically.

### Outbox-backlog bound (Week 12 box 2)

`Admission:MaxOutboxBacklog` (default `0` = off; only consulted when
`Admission:Enabled=true`) adds a second, earlier refusal inside Layer 2. When
the Order Outbox already holds that many unpublished rows, a brand-new order is
refused with **503** + `Retry-After: 1` and
`flashsale_admission_rejected_total{reason="backlog"}` is incremented, before
anything is written. It exists for the case the concurrency gate cannot see: the
broker down, a queue full, or Inventory slow, so accepted orders keep piling up
unpublished in the Outbox. The concurrency gate bounds *in-flight* new orders;
the backlog bound bounds *unpublished* accepted orders.

- **What is counted where.** The backlog is read from `OutboxBacklogMonitor`, a
  singleton whose estimate is the `OutboxPublisherWorker`'s last measured count
  plus the orders this process has accepted since that measurement: the worker
  publishes the count it already computes for `flashsale_outbox_unpublished`,
  and the controller calls `RecordAccepted()` once a *new* order and its Outbox
  row are saved (never on a replay). No per-request `count(*)` runs: the gate
  reads one in-memory value. The refusal is counted separately from the
  concurrency 503 as `flashsale_admission_rejected_total{reason="backlog"}`,
  pre-created at 0 at startup like the `concurrency` series.
- **Order of checks** in `CreateOrderAsync`: idempotency lookup (unchanged) →
  backlog check → concurrency gate → the existing order+Outbox save. A retry of
  an accepted order is answered from the existing row (200/409) before either
  bound, so an accepted order always gets its original order back even when the
  backlog is full. The backlog check touches nothing in the database or Redis.
- **The soft bound.** The estimate is the last measured count plus everything
  admitted since, so a newly-accepted order is reflected immediately — it does
  not wait for the next poll, whose cadence can stretch to minutes when the
  broker is down (the per-message retry ladder). The bound can therefore only be
  overshot by requests that pass the check concurrently, which the concurrency
  gate already caps. This is stated here deliberately, not hidden.
- **Unknown backlog.** Before the first poll the monitor reads 0 (its initial
  value), so a pre-existing backlog from before this process started is treated
  as **admit** (the concurrency gate still applies). This is chosen over refusing
  because a just-started service must not shed valid load on a count it has not
  measured yet. New orders accepted after start are reflected immediately via
  `RecordAccepted`, and the pre-existing count is enforced once the first poll
  runs.

### In-flight bound (added after the external review of Week 12)

`Admission:MaxInFlightOrders` (default `0` = off; only consulted when
`Admission:Enabled=true`) refuses a brand-new order with **503** +
`Retry-After: 1`, counted as `flashsale_admission_rejected_total{reason="inflight"}`,
while that many orders are still unfinished anywhere in the pipeline
(`PendingStock`, `Confirmed` or `Processing`). Why it exists: the backlog bound
only protects the first hop. Once every consumer set a prefetch, the TP-L04
overload showed the real picture: Order Service accepted about 13 orders/s
while the Process Worker finishes about 3.7/s, so work piled up downstream
(first behind the Worker's bounded queue, which also held back Inventory's
`StockReserved` to Order Service, so orders sat in `PendingStock` for ~32 s),
and the backlog took ~105 s to clear. Bounding the unfinished orders refuses
at the door what the slowest stage cannot absorb.

- **Estimate.** `InFlightOrdersMonitor` shares `AdmissionCountEstimate` with
  the backlog monitor: the last measured count plus the orders accepted since.
  `InFlightOrdersRefresher` measures the count every
  `Admission:InFlightRefreshMilliseconds` (default 1000) with one indexed query
  (`IX_orders_State`) and exports it as `flashsale_orders_in_flight`. It runs
  only when the bound is on, so C2 pays nothing. A failed measurement keeps the
  last estimate, which only grows with new accepts, so the bound errs towards
  refusing.
- **Order of checks:** idempotency lookup → backlog → in-flight → concurrency
  gate → save. A retry of an accepted order is still answered before every
  bound.
- **The count is the whole database**, as it must be in production. The
  verifiers share one database that other suites leave non-terminal fixtures
  in, so cases I and H set the bound relative to the measured baseline.
- **Value.** Pre-pilot, case H uses the baseline + 30: the Worker finishes
  ~3.7 orders/s and the recovery phase still offers 3/s, so a backlog clears at
  ~0.7/s while recovery load continues, and ~30 orders above the steady level
  is what can clear within the 60 s target. The Week 13 pilot sets the value.

## Layer 3 — RabbitMQ bounded queues (a policy, not queue arguments)

`scripts/set-queue-bounds.ps1 -Container <rabbit> -MaxLength <n> [-Remove]`
sets (or removes) one policy, `flashsale-c3-bounds`, whose `max-length` is the
bound and whose `overflow` is `reject-publish`. It matches **only** the six main
input queues and never a `.dlq` or `.retry.N` queue:

`OrderPlaced`, `StockReserved`, `StockRejected`,
`ProcessWorker.StockReserved`, `OrderProcessingStarted`, `OrderProcessed`.

It is a policy rather than queue arguments because a policy can be added and
removed at runtime without re-declaring any queue (Claude's prototype: a
`max-length=2, overflow=reject-publish` policy capped `OrderPlaced` at 2,
rejected the 3rd/4th publish, and deleting the policy removed the bound with no
redeclare). The services' queue declarations are unchanged.

## Publisher at capacity (no code change)

Every publisher already publishes with `mandatory: true` and tracked confirms
(`RabbitMqOutboxPublisher` in Order and Inventory; the Worker's two publishers),
so a `reject-publish` nack at a full queue throws from the awaited
`BasicPublishAsync` and the Outbox row is left unpublished, to be retried on the
next poll (proven by TP-O02, case E). No publisher code changes for this box.

**Fan-out note:** `StockReserved` is published by Inventory to *two* queues —
`StockReserved` (Order Service) and `ProcessWorker.StockReserved` (the Worker),
both bound to the same routing key. A direct exchange copies the message to
every bound queue, so if one of the two is full the publish is nacked as a
whole while the *other* queue may already hold its copy. The Outbox retry then
delivers the message again, and the copy already delivered is absorbed by the
receiving service's Inbox (the `MessageId` is stable), so the result is still
applied exactly once. The verifier's bounded-queue case proves the net effect —
one reservation per order, `SCARD processed:<p> = N`, stock = initial − N — even
though it does not stage a single-queue-full fan-out.

## C2 vs C3 — every C3 switch

C2 is the current behaviour and every existing verifier must still pass with
the switches off. C3 turns on any combination of:

| Switch | Default (C2) | C3 |
|---|---|---|
| `ORDER_RATE` / `ORDER_BURST` (Nginx env) | 200r/s / 100 (generous) | set from the Week 13 pilot |
| `Admission:Enabled` | `false` | `true` |
| `Admission:MaxConcurrentNewOrders` | 64 | set from the Week 13 pilot |
| `Admission:MaxOutboxBacklog` | `0` (off) | set from the Week 13 pilot |
| `Admission:MaxInFlightOrders` | `0` (off) | set from the Week 13 pilot (case H: baseline + 30) |
| `flashsale-c3-bounds` policy | absent | `max-length=<n>, overflow=reject-publish` |

With every switch off, a POST that reaches Order Service behaves exactly as it
does today in C2.

## How strict each bound is (midterm review)

| Bound | Scope | Hard or approximate | Permitted overshoot | After a restart |
|---|---|---|---|---|
| Nginx `limit_req` | one Nginx instance, one shared key for `POST /api/orders` | hard at the gateway (leaky bucket) | the configured `burst` | the bucket starts empty |
| Admission concurrency gate | one Order Service process | hard per process (`TryEnter`, no queueing) | none per process; N processes admit N × the limit | slots start free |
| Outbox-backlog bound | one Order Service process | approximate: last measured count + this process's accepts since then | up to `MaxConcurrentNewOrders` orders that passed the check together before any was recorded; another process's accepts are not seen until the next measurement | the estimate is 0 until the first measurement (one Outbox poll), so it admits; the concurrency gate still applies |
| In-flight bound | one Order Service process | approximate, same estimate; refreshed every `InFlightRefreshMilliseconds` (1 s) | as above. It is conservative between refreshes: finished orders are counted until the next refresh, so it can refuse slightly early | 0 until the first refresh (≤ 1 s) |
| RabbitMQ `max-length` + `reject-publish` | each of the six main queues | hard on **ready** messages only | unacknowledged deliveries are not counted: up to `prefetch × consumers` (20 per consumer) more | the policy is stored by the broker and survives a broker restart; reapply it after a fresh broker volume |
| Consumer prefetch | one consumer channel | hard (the broker stops delivering) | none | per channel; a reconnecting consumer gets a fresh window |

Accepted work is never dropped by a bound. Admission refuses before any
database write. A full queue nacks the publish, so the row stays in the Outbox
and is retried. A ready-only queue count is not the whole pipeline: total work
in progress is the two Outbox backlogs, plus ready and unacknowledged messages
in every main queue, plus accepted orders not yet in a terminal state. The
extractor's drain and `max_total_backlog` use that total, not the ready count.

The restart behaviour in the last column follows from the code; it is not
injected by a verifier.

## Verification

`scripts/verify-load-shedding.ps1` (TP-L01, TP-L02, TP-L04) covers the cases: A (gateway
429 with no order row for a 429 key, and GET polling never 429), B (admission
503 with `Retry-After`, no order row for a 503 key, the metric rising by
exactly the 503 count, and a replay of an accepted key returning 200 while the
gate is full), C (bounded `OrderPlaced` + Outbox backlog + full drain with one
reservation per order), D (C2 unchanged: every limit off, all orders accepted
and processed), E (Outbox-backlog admission: some 201s then 503 with
`reason="backlog"` rising by exactly the 503 count, no order/Outbox row for a
503 key and Redis unchanged, a replay of an accepted key returning 200 while the
backlog is full, and a full drain with `SCARD` = accepted and stock = initial −
accepted once the broker returns), F (`validate-correctness.ps1 -Config C3` with
check 5 PASS after the drain, and the negative fixture — Inventory stopped, one
order left PendingStock — INCONCLUSIVE with the order listed and exit 1), and G
(the run-time collector's CSV shows `flashsale_outbox_unpublished`,
`flashsale_admission_rejected_total{reason="backlog"}` and a RabbitMQ queue
depth, with the backlog rising above 0 while the broker is down), and H (box 4:
overload, drain and recovery — the section below). Negative
controls (Claude runs them): admission disabled → B fails; policy not set → C
fails; Nginx rate set very high → A fails; `MaxOutboxBacklog=0` → E fails; check
5 removed → F's negative fixture passes wrongly (F fails).

## Overload, drain and recovery (Week 12 box 4, TP-L04 case H)

Box 4 turns all three C3 layers on at once and drives them with a three-phase
JMeter plan to prove that a backlog drains and the system returns to the stable
range **without a full restart**.

### The three phases

`tests/jmeter/overload-recovery.jmx` runs three open-loop phases in one run,
each an arrival rate paced by a Constant Throughput Timer (enough threads that
the timer, not the response time, sets the rate). Every POST carries a unique
`Idempotency-Key`; the POST sampler label contains `submit`, the poll sampler
`poll`, and the phase name is in the label so the verifier can read per-phase
numbers from the JTL. 429 and 503 are asserted as acceptable overload responses;
any other non-2xx fails the sample.

The baseline and recovery rates are set **below** the Process Worker's measured
capacity: the Worker drains at ~3.7 msg/s (its fixed 200 ms delay plus publish
overhead, run 3), so a 5 r/s baseline/recovery is itself above capacity and the
Worker's in-flight backlog keeps growing during "recovery" — which can never
show a return to a stable range. 3 r/s keeps the steady-state Worker backlog
near zero, so the recovery phase is a true recovery; the overload phase stays
well above every limit.

| Phase | Rate | Duration | What it proves |
|---|---|---|---|
| baseline | 3 r/s | 30 s | orders are accepted normally below every limit |
| overload | 60 r/s | 60 s | the offered rate exceeds `ORDER_RATE=20r/s` and the admission limits, so 429/503 appear |
| recovery | 3 r/s | 60 s | back at the baseline rate (below Worker capacity), the backlog drains and latencies return to the stable range |

Polling is a **bounded** sample (every 10th accepted order, polled 3 times),
never an unbounded poll-until-terminal loop.

### What is measured (three numbers)

The collector (`scripts/collect-run-metrics.ps1`) samples queue depth, the
Outbox gauges, `flashsale_*` metrics, PostgreSQL and host CPU/memory across the
run. Case H turns those samples and the JTL into three distinct numbers:

- **Backlog drain after overload** — from the end of the overload phase until
  all queued work is back to **≤ the baseline phase's maximum** (its
  steady-state level), *while the recovery load continues*. Queued work is both
  services' unpublished Outbox rows plus the main queues' ready **and**
  unacknowledged messages. Until the review after Week 12 this counted only the
  Order Outbox and ready messages, and no consumer set a prefetch, so the
  Process Worker held its whole backlog as unacknowledged messages outside both
  the queue bound and this number (the earlier 3.9 s / 2.4 s). Every consumer
  now sets a prefetch (`RabbitMQ:EventBus:PrefetchCount`, default 20), so a
  queue's `max-length` bounds real work and the excess waits in the publishing
  service's Outbox, where it is counted. It is computed in case H from
  `samples.csv`, not from the extractor; case H also checks that no consumer
  held more than its prefetch unacknowledged.
- **Final drain** — `extract-run-metrics.ps1`'s `drain_time_s` run with `-To` =
  the **last submission of the whole run**, so it measures clearing whatever is
  left after load stops (the TP-P08 definition: last submission → every queue
  ready **and** unacknowledged = 0, both Outbox gauges = 0 and the pending-order
  count = 0). The Process Worker's 200 ms-per-message delay dominates this: the
  backlog left at the last submission drains at ~3.7 msg/s. The case keeps the
  collector sampling for two intervals after the drain is detected, so the
  all-zero sample is written and the extractor can find it.
- **Recovery** — `extract-run-metrics.ps1`'s `recovery_time_s` (with the
  `-StableRange` below): from the first `submit-recovery` sample to the start
  of the first 10 s window whose own submissions are in range, with accepted
  (2xx) throughput and refusals counted (docs/metrics.md). Until the review
  after Week 12 it was "drained − To", which equals the final drain by
  definition and could pass while every request was refused. The saved local
  run re-extracted with the new definition gives 7 s with no refusals allowed
  and the Outbox back at its baseline (≤ 7), and 0 s if refusals are ignored.

### Stated thresholds (local, preliminary — fixed at the Week 13 pilot)

- backlog drain after overload ≤ 60 s.
- final drain (`drain_time_s`) ≤ 120 s — raised from the round-1 30 s because
  the 200 ms-per-order Worker makes 30 s impossible (run 3: ~277
  `ProcessWorker.StockReserved` messages at ~3.7 msg/s ≈ 76 s; 120 s leaves
  headroom).
- the recovery phase has 0 non-429/503 errors and p95 ≤ 1000 ms.
- the extractor's `-StableRange` is `max_p95_ms=1000`, `max_error_pct=0.0`,
  `max_refused_pct=0.0`, `min_throughput_per_s=1.0` (accepted orders per
  second), judged per 10 s window after overload removal: a window in which
  any request is still refused does not count as recovered. The pilot may add
  `max_outbox_backlog`.

These values are **local/preliminary** laptop numbers for proving the mechanism;
the Week 13 pilot fixes the real thresholds. No accepted work is lost: after the
drain `validate-correctness.ps1 -Config C3` passes (check 5), the Outbox is 0,
the six main queues are empty, `SCARD processed:<p>` = accepted and
`stock = initial − accepted`; the three service processes keep the same PIDs
across the run (no restart).
