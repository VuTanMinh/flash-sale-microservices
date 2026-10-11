# Process Worker: deterministic downstream processing (Week 11)

`scripts/verify-worker.ps1` (test case TP-P01) proves that the Process Worker's
downstream work is deterministic — a fixed configured delay and a success-only
result — and that exactly one completion result is applied per order under
replay, restart and event reordering. This document records how the Worker is
built and what the verifier checks.

## Deterministic delay, and why

The Worker simulates downstream processing by waiting a fixed
`Processing:DelayMilliseconds` (default 200 ms, configurable) and then publishing
`OrderProcessed` — see `ProcessingOptions.cs`. The delay is deliberately a fixed
value, not a random or normally-distributed one: a deterministic service time
means any variance measured in end-to-end latency comes from queueing,
contention and the architecture itself, not from the simulator adding noise of
its own (the reason Week 13/14 vary this value). The delay is *inside* the
retry loop, so a retry re-does the work rather than publishing a completion for
processing that never actually ran to completion.

Case A of `verify-worker.ps1` asserts the delay: with
`Processing__DelayMilliseconds=500`, each Worker line
`Order {OrderId} processed in {ElapsedMs}ms` is at least 500 ms and below
500 ms + a stated tolerance (1500 ms).

## Completion identity: `MessageId = OrderId`

The Worker has no database of its own, so it cannot record what it has already
handled. It derives the published `OrderProcessed` message identity from the
order id: `MessageId = OrderId` (see `OrderProcessedEto.cs`). A redelivered
`StockReserved` therefore regenerates a byte-identical `OrderProcessed`, which
Order Service's Week 9 Inbox dedupes with no extra machinery — the idempotency
key travels in the message rather than living in a store.

Case A asserts this: every applied `OrderProcessed` has one Order Inbox row with
`MessageId = OrderId`.

## ACK after the confirmed publish

The Worker publishes `OrderProcessed` with publisher confirmations enabled and
tracked, so `BasicPublishAsync` returns only once the broker has confirmed the
message (`OrderProcessedPublisher.cs`). The input `StockReserved` is acked only
*after* that confirmed publish (and after the Week 9 fault-injection hook that
is a no-op unless configured). There is no Outbox here, and that is not an
inconsistency: an Outbox exists to stop a local business write and a publish
from disagreeing, and the Worker performs no local write — it only waits, then
publishes. A crash anywhere in the sequence leaves the input unacknowledged, so
the broker redelivers it.

## Crash and graceful shutdown

On a **crash** (`Stop-Process -Force`, or a power loss) the Worker dies with the
input unacknowledged. The broker redelivers the `StockReserved`, the Worker
re-runs the deterministic delay, and publishes the byte-identical completion,
which Order Service dedupes. Exactly one completion is applied.

On a **graceful shutdown** (Ctrl+C / SIGTERM) the host's stopping token is
cancelled. Before this fix, the cancelled delay surfaced as an
`OperationCanceledException` that the retry loop treated as a failed attempt,
and the retry wait threw again outside the loop — so every in-flight order was
logged as an error, counted in `DeadLetteredTotal` and dead-lettered. A routine
restart therefore turned accepted orders into dead letters.

After the fix (`StockReservedConsumer.cs`):

* an `OperationCanceledException` thrown because the host's stopping token is
  cancelled is **not** a failed attempt — it is rethrown out of the retry loop
  instead of being retried;
* the message is left unacked (no `BasicNack` is issued), so the closing channel
  requeues it to the broker;
* one Information line is logged —
  `Shutdown during processing of order {OrderId}; returning it to the queue`;
* the message is **not** logged as an error, not counted in
  `DeadLetteredTotal` and not sent to the DLQ.

Real failures are unchanged: they still run the 1 s / 2 s / 4 s ladder to the
DLQ, and invalid messages still go straight to the DLQ.

Cases E1 (real Ctrl+C) and E2 (hard crash) of `verify-worker.ps1` assert this:
the DLQ stays empty, the message is returned to the queue, and after the Worker
restarts every order reaches `Completed` with exactly one applied completion.

## Attempts versus applied

The Prometheus counter `flashsale_orders_processed_total` (scraped by
`infra/prometheus.yml` job `process-worker`) counts **work attempts** — every
time the Worker finishes its delay and confirms a publish, including replays and
concurrent copies. The **business result** is the durable Order completion: one
`order_service.processed_messages` row per order with `MessageId = OrderId`.
The two are reported separately: cases B/C/D assert the counter rises by the
number of replayed copies while the Inbox row count stays at one and
`CompletedAt` is unchanged.
