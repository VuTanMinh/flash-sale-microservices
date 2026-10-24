# Metrics and stage timestamps (Week 11)

This is the metric dictionary the experiments will be measured with. It covers
every metric in the teacher brief (§6) and in Notion 04 "Metric definitions".
For each metric it gives the definition, where the raw value comes from, how it
is extracted, and whether that source **exists now** or is still to be built.
`scripts/verify-metrics.ps1` (TP-P04) checks that every Prometheus metric
marked *Exported* below exists and moves by the expected amount.
`scripts/trace-order.ps1` (TP-P03) checks that one order can be traced across
all services by its ids and stage timestamps.

Rules (Notion 04, study guide):

- **One source per metric.** The extraction query or script is fixed before
  the official runs (Week 13).
- **Never invent a value.** A missing or negative interval is reported as
  missing, never as 0.
- **Ids stay out of labels.** Metric labels are low-cardinality (consumer,
  outcome, reason). Order ids and message ids belong in logs and database
  rows, never in labels.
- **Attempts are not completions.** Work attempts (Worker processing, retries)
  are counted separately from applied business results (Inbox rows, history
  rows).

## Status values

| Status | Meaning |
|---|---|
| **Exported** | A Prometheus metric that exists now; TP-P04 checks it. |
| **Available** | A database column, JMeter field, broker API or log line that exists now; extraction is a query or a parse. |
| **Week 12** | Depends on the overload layer (Nginx limits, admission, bounded queues), which is not built yet. |
| **Week 13–14** | Needs the pilot or official-run tooling (JMeter plans, host monitoring, analysis scripts). The raw source may already exist; the extraction is not built. |

## Stage timestamp schema

All times are UTC (`DateTime.UtcNow`), truncated to microseconds, and come from
one host's clock: the experiments run every backend service on one EC2
instance. EF-migrated columns are `timestamp without time zone` holding UTC
values.

| Stage | Column | What moment it records | Caveat |
|---|---|---|---|
| Request acceptance | `order_service.orders.RequestAcceptedAt` | When Order Service builds the order, just **before** the order + Outbox transaction commits | The order is only durable after the commit. The client's response follows the commit, so true acceptance is slightly later (Notion 04). |
| Event publication | `order_service.outbox_events.PublishedAt` (event type `OrderPlaced`) | When the publisher marks the row published, **after** the broker's routed confirm | A row is marked after the confirm, so `PublishedAt` trails the moment the broker accepted it. The consumer can even decide **before** the row is marked: a trace once showed `PublishedAt` 0.13 ms after Inventory's decision. So publication ≤ decision is not an invariant; publish-to-decision intervals can be slightly negative and are reported as anomalies, never clamped. |
| Stock processing (decision) | `inventory_service.outbox_events.CreatedAt` (the result row for the order) | When Inventory writes the `StockReserved`/`StockRejected` result, in the same transaction as its Inbox row, right after the Lua decision | Inventory's own Inbox `processed_messages.ProcessedAt` is the same moment. |
| Result publication | `inventory_service.outbox_events.PublishedAt` | After the broker confirm for the result | As for event publication. |
| Decision applied by Order | `order_service.orders.ConfirmedOrRejectedAt` | When Order Service applies the result | Also a history row (`PendingStock → Confirmed/Rejected`). |
| Processing start | `order_service.order_status_history.At` for `Confirmed → Processing` | When Order Service applies `OrderProcessingStarted`; for an **implied** row, the later of the Worker's start time and the confirmation time | Implied rows are flagged (`Implied = true`). |
| Completion | `order_service.orders.CompletedAt` | When Order Service applies `OrderProcessed` | Also a history row (`Processing → Completed`). |
| Full history | `order_service.order_status_history` | One row per applied transition, ordered by `Seq` | A duplicate or stale event writes no row. |

`scripts/trace-order.ps1` checks the order of these values for real orders. It
checks acceptance ≤ publication, and acceptance ≤ stock decision ≤ decision
applied ≤ completion. It prints a publication mark that trails the decision as
an anomaly, and checks that the history rows match.

## Message timestamps

Every message published by the three services carries the AMQP `timestamp`
property, set to the Unix seconds (UTC) at the moment of publish:
`BasicProperties.Timestamp = new AmqpTimestamp(DateTimeOffset.UtcNow.ToUnixTimeSeconds())`.
A requeued copy gets the time it is requeued, so the age measures time spent
waiting in a queue, not time since the original event. That property is what
lets the broker report the oldest-message age as `head_message_timestamp`
(management API `GET /api/queues/%2F/<q>`). That value is a management
statistic refreshed every `collect_statistics_interval` (5 s by default), so
the reported age has a resolution of that interval plus 1 s.

Six publish sites set it:

- Order Service's `RabbitMqOutboxPublisher` (`OrderPlaced`);
- Inventory Service's `RabbitMqOutboxPublisher` (`StockReserved`/`StockRejected`);
- the Process Worker's `OrderProcessingStartedPublisher` and `OrderProcessedPublisher`;
- Order Service's two delayed-requeue paths (`OrderProcessed` and
  `OrderProcessingStarted`).

`scripts/verify-message-timestamps.ps1` (TP-P06) checks, for each of those six
paths, that a message left sitting in a queue carries a fresh timestamp and that
the queue's `head_message_timestamp` age grows while the message waits. A
source-scan unit test (`MessageTimestampSourceScanTests`) fails if any future
`new BasicProperties` in `src/` is added without a `Timestamp`.

## Run-time collection

`scripts/collect-run-metrics.ps1` samples the run-time-only sources while a
load run is in progress and appends one row per value to `<OutDir>/samples.csv`
in long format `utc_time,source,name,labels,value` (UTC time, source name,
metric name, `key=value` labels joined by `;`, and the numeric value). It also
writes `<OutDir>/collector.json` once at start (run id, interval, endpoints,
host OS, start time, git commit). The sampling interval is `-IntervalSeconds`
(default 5 s); `-DurationSeconds 0` samples until a file `<OutDir>/STOP`
appears. One sample takes about 4 s on the local Windows host (two
`docker exec` calls of about 1 s each), so the interval must be at least 5 s;
on the EC2 host, read `sample_duration_ms` in the pilot to set the interval.

| Source | `name` | Unit | Meaning |
|---|---|---|---|
| `rabbitmq` | `messages_ready`, `messages_unacknowledged` | messages | Per-queue ready and unacknowledged counts from the management API (`labels` = `queue=<q>`). These and `head_message_timestamp` are statistics refreshed every `collect_statistics_interval` (5 s by default; 1 s on the throwaway verifier broker), so a value can be that interval stale. |
| `rabbitmq` | `oldest_age_seconds` | seconds | `now − head_message_timestamp` per queue; 0 only when the queue is empty. A queue that has messages but no head timestamp yet (statistics lag) is `unavailable`, as is any null count. Same resolution caveat. |
| `rabbitmq` | `publish_rate`, `deliver_get_rate`, `ack_rate` | messages/second | Broker overview message rates (`message_stats.*.rate`). |
| `redis` | `calls`, `usec` | calls, microseconds | Cumulative `INFO commandstats` totals for the Lua commands (`labels` = `command=evalsha`/`eval`). Mean latency per interval = Δusec/Δcalls (Task C). |
| `postgres` | `connections` | sessions | `pg_stat_activity` sessions grouped by `usename` (`labels` = `usename=<u>`). |
| `service` | every `flashsale_*`, `process_cpu_seconds_total`, `process_working_set_bytes` | metric unit | One row per Prometheus sample scraped from each service's `/metrics` (`labels` = `service=<job>` plus the sample's own labels). |
| `host` | `cpu_percent` | % | Host CPU usage (Windows performance counters; Linux `/proc/stat`, checked in a Linux container: `tests/evidence/20261014T150746Z-collector-linux-host.log`; confirm on the EC2 host in Week 12). On Linux the first sample's CPU is `unavailable`, because it needs two readings. |
| `host` | `memory_used_bytes`, `memory_total_bytes` | bytes | Host memory (Windows CIM; Linux `/proc/meminfo`). |
| `collector` | `sample_duration_ms` | milliseconds | How long one sample took. The real cadence is visible from it and from the `utc_time` gaps; each sample's rows are written in one append. |

A source that fails is recorded as a row with value `unavailable` and the error
in `labels`, never as 0; the collector counts the failures, prints them at the
end and keeps sampling the other sources. It never stops for one failing
source, and it never issues per-order queries.

## Extraction

`scripts/extract-run-metrics.ps1` turns one run's raw data into the numbers the
report Results tables (Chapter 12, `tab:results-*`) ask for. It is the fixed
"one extraction query/script per metric" Notion 04 requires before the pilot,
so every definition is decided now and not during Week 13.

Command (from the repo root):

    powershell -File .\scripts\extract-run-metrics.ps1 -RunId <id> -Container <pg-container> [-JtlPath <dir>\raw.jtl] [-From <utc> -To <utc>]

- `-RunDir` defaults to `experiments/<RunId>`; `-JtlPath` defaults to
  `<RunDir>/raw.jtl`. `-From`/`-To` are the UTC run window (default: first and
  last JTL sample). A missing JTL makes the JTL block `unavailable` and requires
  `-From`/`-To`. `-SubmissionLabelPattern`/`-PollingLabelPattern` (defaults
  `submit`/`poll`) class a JTL row as a submission or a polling request by its
  sampler label.
- Outputs: `<RunDir>/summary.json` (every group carries a `source` naming where
  the number came from) and `<RunDir>/stage-intervals.csv` (one row per
  accepted order; an empty cell is a missing value).
- **Percentile method: nearest-rank.** p_k = the value at rank ceil(k/100 × n)
  in the sorted (non-missing) list, 1-based. Negative stage intervals are kept
  and counted, never clamped to 0; missing values are counted, never guessed.
- `recovery_time_s` needs `-StableRange @{max_p95_ms=...; max_error_pct=...; min_throughput_per_s=...}`
  (optionally `max_refused_pct`, `max_outbox_backlog`, `max_total_backlog`);
  without it the value is `unavailable`, never 0. It is the time from overload
  removal (`-OverloadEnd`, else the first submission labelled `recovery`) to the
  start of the first `-StableWindowSeconds` window (default 10 s) whose own
  submissions are in range. A window is in range only when it has at least one
  2xx submission, its p95 latency judged on **2xx submissions only** is at most
  `max_p95_ms` (fast 429/503 refusals cannot make latency look good, and a
  window with no 2xx is never in range), internal errors (5xx except 503) are
  at most `max_error_pct`, refusals (429 + 503) are at most `max_refused_pct`
  (when given), accepted (2xx) throughput is at least `min_throughput_per_s`,
  and the window is **sustained** (every 1-second slot inside it holds at least
  one submission — a gap is missing evidence, not stability). When
  `max_outbox_backlog` is given, the Order Outbox gauge at the window start is
  at most it; when `max_total_backlog` is given, the total backlog at the window
  start — Order Outbox unpublished + Inventory Outbox unpublished + every main
  queue's `messages_ready + messages_unacknowledged`, each read from the latest
  sample at or before the start (a missing series is never 0) — is at most it.
  No such window gives `not_recovered`; a database query failure after the
  reachability probe gives `unavailable` (recovery cannot be certified while the
  database is down). The summary records `overload_removed_utc`, the window
  length and which criteria were applied. (Before the review after Week 12 the
  thresholds were checked on the whole run with offered throughput and refusals
  excluded, so a phase that refused everything still counted as recovered.)
- Run membership: when the JTL has an `idempotencyKey` column, the database
  block counts exactly the orders whose key the run submitted
  (`database.run_membership` says so); otherwise it falls back to the
  acceptance time window. Stage times use the original `OrderPlaced` row and
  the first Inventory result row, so a reconciliation re-publish never adds a
  second row for an order. A failed SQL query stops the extraction (non-zero
  exit) instead of being read as 0.
- `drain_time_s` runs from the last JTL submission until the first sample where
  every queue, both Outbox gauges and the exact pending-order count are 0.
  "Pending" is orders accepted inside the run window by that sample time that
  are not yet terminal at it (no `CompletedAt`, and not a rejection with
  `ConfirmedOrRejectedAt`); it is read from `order_service.orders` with one query
  per run (bounded to the run window so a stale order from an earlier run is not
  counted), not from the stuck-orders gauge. A failed or empty pending query
  leaves `drain_time_s` `unavailable` (never inferred as 0). A database query
  failure after the reachability probe makes the database block
  `unavailable (query failed: …)` with no numeric counts, leaves `drain_time_s`
  and `recovery_time_s` `unavailable`, still writes `summary.json`, and exits
  with code 2.

Summary fields map to the Results tables as follows:

| Results column | summary.json field |
|---|---|
| API latency p50/p95/p99, Max | `jtl.submission_elapsed_ms` (polling reported separately: `jtl.polling_elapsed_ms`) |
| Stock-decision latency | per-order `stages_ms.accepted_to_published` + `published_to_decided` |
| Completion latency | `stages_ms.accepted_to_completed` |
| Incoming throughput (/s) | `jtl.offered_throughput_per_s` |
| Accepted / completed throughput (/s) | `database.accepted_count` / `completed_count` divided by the window |
| Reserved / stock-rejection rate | `database.stock_rates_pct` |
| Overload rejection % / internal error % | `jtl.overload_rejection_pct` / `jtl.internal_error_pct` |
| Stage split (5 rows) | `database.stages_ms.*` |
| Peak queue depth / oldest age | `collector.peak_queue_depth` / `collector.peak_oldest_age_seconds` |
| Drain / recovery time | `collector.drain_time_s` / `collector.recovery_time_s` |
| Retries / duplicates / DLQ / reconciliation | `collector.counters.*` |
| CPU / RAM / DB conns / Redis / broker rates | `collector.host_*`, `process_*`, `db_connections`, `redis_mean_latency_us`, `broker_rates` |

## Metric dictionary

| Metric | Definition (boundary, denominator) | Source | Extraction | Status |
|---|---|---|---|---|
| API latency p50/p95/p99 | Client submission to HTTP response, per request; polling requests reported separately | JMeter JTL (`elapsed`, `label`, `responseCode`) | `extract-run-metrics.ps1` (`jtl.submission_elapsed_ms`; polling `jtl.polling_elapsed_ms`) | Available (JTL); extraction built |
| Stock-decision latency | From a common request-start origin to the durable decision. For C2–C4: `RequestAcceptedAt` to Inventory's result `CreatedAt`. The acceptance-to-decision interval is labelled as a separate async stage. | Database columns above; C1: JTL (synchronous decision) | `extract-run-metrics.ps1` (`stages_ms.accepted_to_published` + `published_to_decided`, per order) | Available (columns); extraction built |
| End-to-end completion latency | Request start to applied `Completed` (`CompletedAt`). Acceptance-to-completion is a separately labelled internal interval. Stock rejections reported separately (`ConfirmedOrRejectedAt`). | `orders.CompletedAt`, `RequestAcceptedAt`; JTL for request start | `extract-run-metrics.ps1` (`stages_ms.accepted_to_completed`) | Available (columns); extraction built |
| Incoming throughput | Offered submissions per second | JMeter JTL | `extract-run-metrics.ps1` (`jtl.offered_throughput_per_s`) | Available (JTL); extraction built |
| Accepted throughput | Unique accepted orders per second (an idempotent replay is not a new order) | `flashsale_orders_accepted_total` (Order); `orders.RequestAcceptedAt` | `rate()` of the counter; or count rows per interval | Exported |
| Completed throughput | Unique orders reaching `Completed` per second | `flashsale_orders_outcome_total{outcome="Completed"}` (Order); `orders.CompletedAt` | `rate()` / count per interval | Exported |
| Worker work attempts | Downstream processing runs, including replays | `flashsale_orders_processed_total` (Worker) | `rate()`; compare with completed throughput | Exported |
| Rejected request rate (overload) | 429/503 responses ÷ offered submissions | JMeter JTL `responseCode` | `extract-run-metrics.ps1` (`jtl.overload_rejection_pct`) | Week 12 (no admission control yet) |
| Admission rejections | `POST /api/orders` requests refused at the admission gate (503), before any order is written; an idempotent replay is answered before the gate and never counted. `reason` is `concurrency` (the concurrency gate is full), `backlog` (the Outbox already holds `MaxOutboxBacklog` unpublished rows) or `inflight` (`MaxInFlightOrders` orders are still unfinished) | `flashsale_admission_rejected_total{reason}` (Order) | Counter (Prometheus) | Exported |
| Internal error rate | Unexpected 5xx ÷ offered submissions | JMeter JTL | `extract-run-metrics.ps1` (`jtl.internal_error_pct`) | Available (JTL); extraction built |
| Stock reservation success rate | Unique committed reservations ÷ unique committed stock decisions, per product and run | `flashsale_stock_decisions_total{outcome}` (Inventory); `inventory_service.outbox_events` (`EventType`) | Ratio of counters; or count result rows by type | Exported |
| Stock rejection rate | Unique committed rejections (`rejected`, plus `not_open` reported separately) ÷ the same denominator. Overload rejection is **not** stock rejection. | Same as above | Same | Exported |
| Duplicate stock decisions | Re-processing of an order that already had a result | `flashsale_stock_decisions_total{outcome="duplicate"}` | Counter | Exported |
| Queue depth | Ready + unacknowledged messages per queue | RabbitMQ management API / `rabbitmqctl list_queues` | collected by `collect-run-metrics.ps1`; `extract-run-metrics.ps1` (`collector.peak_queue_depth`) | collected + extracted |
| Oldest message age | Age of the oldest queued message | RabbitMQ management API (`head_message_timestamp`) | collected by `collect-run-metrics.ps1`; `extract-run-metrics.ps1` (`collector.peak_oldest_age_seconds`) | collected + extracted |
| Outbox backlog | Unpublished Outbox rows, and the age of the oldest one | `flashsale_outbox_unpublished`, `flashsale_outbox_oldest_unpublished_age_seconds` (Order and Inventory) | Gauge | Exported |
| Pending order count | Orders not yet in a terminal state (`PendingStock`, `Confirmed`, `Processing`) | `order_service.orders.State`; `flashsale_reconciliation_stuck_orders` for the ones past the timeout | Query by state | Available / Exported |
| Backlog drain time | From the end of submissions until every queue, the Outbox and the pending orders are empty | Queue depth + Outbox gauges + pending count (orders accepted inside the run window by `t` that are not yet terminal at `t`, read from `order_service.orders`, one query per run) | `extract-run-metrics.ps1` (`collector.drain_time_s`; `unavailable` on a failed/empty pending query) | Available (samples); extraction built |
| Recovery time | From overload removal until backlog drains and latency, errors, refusals and accepted throughput are back in the pilot-defined range for a whole window | JTL submissions after overload removal (p95 judged on 2xx only; a sustained window with no 1-second gap); Order Outbox + Inventory Outbox gauges + main-queue depth for `max_total_backlog` | `extract-run-metrics.ps1` (`collector.recovery_time_s`, needs `-StableRange`) | Week 12 / Week 13–14 (overload layer); `unavailable` without `-StableRange` or on a DB failure, `not_recovered` when no window is in range |
| Retry count | Retry waits inside consumer retry ladders | `flashsale_consumer_retries_total{consumer}` (all three services) | Counter (Prometheus); `extract-run-metrics.ps1` `collector.counters.retries` (reset-aware increase from samples) | Exported |
| Duplicate-message count | Messages acked as already processed (Inbox hit or unique-violation race) | `flashsale_consumer_duplicates_total{consumer}` (Order, Inventory) | Counter (Prometheus); `extract-run-metrics.ps1` `collector.counters.duplicates` | Exported |
| Early-event requeues | Worker events requeued because the order was not yet ready | `flashsale_consumer_requeued_early_total{consumer}` (Order) | Counter | Exported |
| DLQ count | Messages routed to a dead-letter queue, by reason (`exhausted`, `invalid`, `conflict`) | `flashsale_consumer_dead_lettered_total{consumer,reason}` (all three); DLQ depth from RabbitMQ | Counter (Prometheus); `extract-run-metrics.ps1` `collector.counters.dead_lettered` | Exported |
| Reconciliation | Re-triggers, orders given up, orders currently stuck | `flashsale_reconciliation_retriggers_total`, `_given_up_total`, `_stuck_orders` (Order) | Counter / gauge (Prometheus); `extract-run-metrics.ps1` `collector.counters.reconciliation` | Exported |
| Worker processing duration | Time from receiving `StockReserved` to the confirmed completion publish | `flashsale_process_worker_duration_seconds` (Worker, histogram) | Histogram quantiles | Exported |
| CPU, RAM per service | Process CPU seconds and memory | prometheus-net defaults: `process_cpu_seconds_total`, `process_working_set_bytes` | `rate()` / gauge | Exported |
| Host CPU, RAM | EC2 instance totals | Host monitoring | `extract-run-metrics.ps1` (`collector.host_cpu_percent`, `collector.host_memory_used_bytes`) | collected + extracted |
| Database connections | Open PostgreSQL sessions per service account | `pg_stat_activity` grouped by `application_name` (each service sets its own) | collected by `collect-run-metrics.ps1`; `extract-run-metrics.ps1` (`collector.db_connections`) | collected + extracted |
| Redis latency | Time per Lua call | Redis `LATENCY` / `INFO commandstats` | collected by `collect-run-metrics.ps1`; `extract-run-metrics.ps1` (`collector.redis_mean_latency_us`, Δusec/Δcalls) | collected + extracted |
| RabbitMQ publish / deliver / ack rates | Broker message rates | RabbitMQ management API (`message_stats`) | collected by `collect-run-metrics.ps1`; `extract-run-metrics.ps1` (`collector.broker_rates`) | collected + extracted |

## Exported Prometheus metrics, by service

| Service (scrape job) | Metric | Type | Labels |
|---|---|---|---|
| Order Service (`order-service`) | `flashsale_orders_accepted_total` | counter | — |
| | `flashsale_orders_outcome_total` | counter | `outcome` |
| | `flashsale_admission_rejected_total` | counter | `reason` |
| | `flashsale_reconciliation_retriggers_total` | counter | — |
| | `flashsale_reconciliation_given_up_total` | counter | — |
| | `flashsale_reconciliation_stuck_orders` | gauge | — |
| | `flashsale_consumer_retries_total` | counter | `consumer` |
| | `flashsale_consumer_duplicates_total` | counter | `consumer` |
| | `flashsale_consumer_dead_lettered_total` | counter | `consumer`, `reason` |
| | `flashsale_consumer_requeued_early_total` | counter | `consumer` |
| | `flashsale_outbox_unpublished` | gauge | — |
| | `flashsale_outbox_oldest_unpublished_age_seconds` | gauge | — |
| Inventory Service (`inventory-service`) | `flashsale_stock_decisions_total` | counter | `outcome` |
| | `flashsale_consumer_retries_total` | counter | `consumer` |
| | `flashsale_consumer_duplicates_total` | counter | `consumer` |
| | `flashsale_consumer_dead_lettered_total` | counter | `consumer`, `reason` |
| | `flashsale_outbox_unpublished` | gauge | — |
| | `flashsale_outbox_oldest_unpublished_age_seconds` | gauge | — |
| Process Worker (`process-worker`) | `flashsale_orders_processed_total` | counter | — |
| | `flashsale_process_worker_dead_lettered_total` | counter | — |
| | `flashsale_process_worker_duration_seconds` | histogram | — |
| | `flashsale_consumer_retries_total` | counter | `consumer` |
| | `flashsale_consumer_dead_lettered_total` | counter | `consumer`, `reason` |
| All three | `process_cpu_seconds_total`, `process_working_set_bytes` | counter / gauge | — |

Label values:

- `consumer`: `OrderPlaced` (Inventory); `StockResult`, `OrderProcessingStarted`
  and `OrderProcessed` (Order); `ProcessWorker.StockReserved` (Worker).
- `outcome` on `flashsale_stock_decisions_total`: `reserved`, `rejected`,
  `not_open`, `duplicate`. The label is the **business** outcome. An attempt
  whose save failed after Redis reserved is not counted. Its retry, which
  writes the order's first result, counts as `reserved`.
- `reason`: `exhausted` (retries used up, or an early event requeued three
  times), `invalid` (malformed JSON, an empty id, or `Quantity` ≠ 1),
  `conflict` (a genuine state conflict). On
  `flashsale_admission_rejected_total` the values are `concurrency` (the
  admission gate is full), `backlog` (the Outbox holds `MaxOutboxBacklog`
  unpublished rows) and `inflight` (`MaxInFlightOrders` orders are not yet
  `Completed` or `Rejected`; the measured count is the gauge
  `flashsale_orders_in_flight`).
- `outcome` on `flashsale_orders_outcome_total`: `Confirmed`, `Rejected`,
  `Processing` and `Completed` count transitions applied by an event.
  `NotYetApplicable` counts early results that were retried. An **implied**
  `Processing` step (the completion arrived first) is counted only as
  `Completed`. Count orders that passed through `Processing` from
  `order_status_history`, not from this counter.

Counters reset when a process restarts. Extraction uses reset-aware `rate()`
or `increase()`, and durable row counts as the cross-check.

`infra/prometheus.yml` scrapes the three services on their default ports
(44314, 44379 and 5100).

## Logs

All three services write structured JSON (`Logs/logs.json`, Serilog compact
format). Every event carries:

- `Service`, the service name;
- `SourceContext`, the class, which is the operation;
- `CorrelationId`, inside message handling and HTTP requests.

The message-handling lines also carry `OrderId` and `MessageId`. Retry lines
carry the attempt (`attempt n/4`), and outcome lines name the result
(`-> Confirmed`, `already processed`, `routing to DLQ`). `scripts/trace-order.ps1`
uses these fields to rebuild one order's path.
