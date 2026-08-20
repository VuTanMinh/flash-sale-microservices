# Test Plan

Written in Week 4, before most of what it describes exists, on purpose:
per the checklist's own reasoning, writing the plan now means Weeks 5–14 are
*executing* a plan, not improvising one under deadline pressure. Update this
file as each piece actually gets built rather than treating it as fixed the
day it was written — a test plan that silently drifts from reality is worse
than no test plan.

## Unit tests per service

| Service | What gets unit-tested | Built |
|---|---|---|
| Order Service | State machine transition guards (legal transitions succeed, illegal ones throw) | Week 5 |
| Order Service | Idempotent order creation (same `Idempotency-Key` → same order, not a duplicate) | Week 5 |
| Order Service | Outbox: order insert + outbox insert roll back together if either fails | Week 6 |
| Order Service | Inbox: duplicate `message_id` delivery processes the business effect exactly once | Week 9 |
| Inventory Service | Redis Lua script outcomes (`RESERVED` / `DUPLICATE` / `REJECTED`) — this is already manually verified via `redis-cli` in Week 7's own checklist step; unit tests wrap the same three cases so they run in CI, not just once by hand | Week 7 |
| Inventory Service | Inbox: same duplicate-delivery guarantee as Order Service, this service's own copy | Week 9 |
| Process Worker | Deterministic-delay completion path | Week 11 |

C0 and C1 (`src/FlashSale.OrderService/Experiments/C0Naive/`,
`Controllers/BaselineOrdersController.cs`) are deliberately **not**
unit-tested — they're one-shot demonstrations (C0 already run and captured,
Week 3), not code with a future to protect. Writing unit tests for
intentionally-broken code protects a bug that's supposed to stay fixed-in-place
as evidence, which isn't what unit tests are for.

## JMeter test plans — what each one checks

| Plan | Purpose | Threads/duration | Pass criterion |
|---|---|---|---|
| `tests/jmeter/smoke-test.jmx` (Week 3) | Pipeline reachability — is the HTTP path actually wired end-to-end | 10 threads, 1 iteration | All requests reach the app and get a real application response (2xx/4xx). **Not** "no errors" — a 404 from an unrelated process on the wrong port looks like a pass on that criterion alone and isn't one; see the Week 3 JMeter-port incident in `FLASHSALE_EXECUTION_CHECKLIST.md` Step 3.5 for a real example. |
| Load test (Week 13) | Throughput/latency (p50/p95/p99) under normal, provisioned-for traffic, per configuration (C1 vs the final async design) | Ramped to the provisioned target rate, sustained | Latency percentiles recorded per `report/report.tex`'s Results chapter templates (Week 11); zero correctness-invariant violations (`docs/inventory-invariants.md`) during the run. |
| Overload test (Week 13) | Behavior once request rate exceeds provisioned capacity — this is what the load-shedding mechanisms (Week 12) exist to control | Ramped past the provisioned target until shedding engages | Excess requests are explicitly rejected (503/429 at Nginx, or an application-level rejection) rather than timing out, crashing, or corrupting state. The *point at which* shedding engages, and *how cleanly*, is itself a reported result, not just a pass/fail gate. |

## Correctness validation — how it actually runs

`scripts/validate-correctness.ps1` (first built Week 8, reused unmodified in
Week 14 against real experimental data) queries Postgres and Redis after a
test run and asserts all four invariants from `docs/inventory-invariants.md`
hold:

1. `available_inventory >= 0`
2. `successful_reservations <= initial_inventory`
3. at most one successful reservation per order
4. duplicate message delivery never produces a second stock deduction

It must accept product ID(s) and expected initial stock as parameters (not
hardcoded) — Weeks 13/14 run it against several different product/stock
configurations, and a hardcoded validator would silently validate the wrong
data without ever failing loudly. Every experiment run, without exception,
is preceded by `scripts/reset-and-seed.ps1` (Week 3) so the validator's
"expected initial stock" is always a known, reproducible value rather than
whatever was left over from the previous run.

## What this plan does not cover

Per `docs/00-scope-lock.md`: no frontend/UI tests (there is no frontend),
no auth/authz tests (out of scope), no multi-region or cluster-failover
tests (single-instance infrastructure only). If a future week's work seems
to need a test in one of these categories, that's a signal the work has
drifted outside scope, not a gap in this plan.
