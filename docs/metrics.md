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

## Metric dictionary

| Metric | Definition (boundary, denominator) | Source | Extraction | Status |
|---|---|---|---|---|
| API latency p50/p95/p99 | Client submission to HTTP response, per request; polling requests reported separately | JMeter JTL (`elapsed`, `label`, `responseCode`) | Percentiles over the JTL rows of order submissions, per run | Available (JTL); percentile script Week 13–14 |
| Stock-decision latency | From a common request-start origin to the durable decision. For C2–C4: `RequestAcceptedAt` to Inventory's result `CreatedAt`. The acceptance-to-decision interval is labelled as a separate async stage. | Database columns above; C1: JTL (synchronous decision) | Per-order join on `OrderId` across both schemas | Available (columns); script Week 13–14 |
| End-to-end completion latency | Request start to applied `Completed` (`CompletedAt`). Acceptance-to-completion is a separately labelled internal interval. Stock rejections reported separately (`ConfirmedOrRejectedAt`). | `orders.CompletedAt`, `RequestAcceptedAt`; JTL for request start | Per-order query | Available (columns); script Week 13–14 |
| Incoming throughput | Offered submissions per second | JMeter JTL | Count per interval | Available (JTL) |
| Accepted throughput | Unique accepted orders per second (an idempotent replay is not a new order) | `flashsale_orders_accepted_total` (Order); `orders.RequestAcceptedAt` | `rate()` of the counter; or count rows per interval | Exported |
| Completed throughput | Unique orders reaching `Completed` per second | `flashsale_orders_outcome_total{outcome="Completed"}` (Order); `orders.CompletedAt` | `rate()` / count per interval | Exported |
| Worker work attempts | Downstream processing runs, including replays | `flashsale_orders_processed_total` (Worker) | `rate()`; compare with completed throughput | Exported |
| Rejected request rate (overload) | 429/503 responses ÷ offered submissions | JMeter JTL `responseCode` | Count by code | Week 12 (no admission control yet) |
| Internal error rate | Unexpected 5xx ÷ offered submissions | JMeter JTL | Count by code | Available (JTL) |
| Stock reservation success rate | Unique committed reservations ÷ unique committed stock decisions, per product and run | `flashsale_stock_decisions_total{outcome}` (Inventory); `inventory_service.outbox_events` (`EventType`) | Ratio of counters; or count result rows by type | Exported |
| Stock rejection rate | Unique committed rejections (`rejected`, plus `not_open` reported separately) ÷ the same denominator. Overload rejection is **not** stock rejection. | Same as above | Same | Exported |
| Duplicate stock decisions | Re-processing of an order that already had a result | `flashsale_stock_decisions_total{outcome="duplicate"}` | Counter | Exported |
| Queue depth | Ready + unacknowledged messages per queue | RabbitMQ management API / `rabbitmqctl list_queues` | Poll during the run | Available; poller Week 13–14 |
| Oldest message age | Age of the oldest queued message | RabbitMQ management API (`head_message_timestamp` needs message timestamps) | Poll | Week 13–14 (publishers do not set a message timestamp yet; until then reported as unavailable, never 0) |
| Outbox backlog | Unpublished Outbox rows, and the age of the oldest one | `flashsale_outbox_unpublished`, `flashsale_outbox_oldest_unpublished_age_seconds` (Order and Inventory) | Gauge | Exported |
| Pending order count | Orders not yet in a terminal state (`PendingStock`, `Confirmed`, `Processing`) | `order_service.orders.State`; `flashsale_reconciliation_stuck_orders` for the ones past the timeout | Query by state | Available / Exported |
| Backlog drain time | From the end of submissions until every queue, the Outbox and the pending orders are empty | Queue depth + Outbox gauges + pending count | Time series | Week 13–14 |
| Recovery time | From overload removal until backlog drains and latency, errors and throughput are back in the pilot-defined range | The series above | Time series | Week 12 / Week 13–14 |
| Retry count | Retry waits inside consumer retry ladders | `flashsale_consumer_retries_total{consumer}` (all three services) | Counter | Exported |
| Duplicate-message count | Messages acked as already processed (Inbox hit or unique-violation race) | `flashsale_consumer_duplicates_total{consumer}` (Order, Inventory) | Counter | Exported |
| Early-event requeues | Worker events requeued because the order was not yet ready | `flashsale_consumer_requeued_early_total{consumer}` (Order) | Counter | Exported |
| DLQ count | Messages routed to a dead-letter queue, by reason (`exhausted`, `invalid`, `conflict`) | `flashsale_consumer_dead_lettered_total{consumer,reason}` (all three); DLQ depth from RabbitMQ | Counter; queue depth | Exported |
| Reconciliation | Re-triggers, orders given up, orders currently stuck | `flashsale_reconciliation_retriggers_total`, `_given_up_total`, `_stuck_orders` (Order) | Counter / gauge | Exported |
| Worker processing duration | Time from receiving `StockReserved` to the confirmed completion publish | `flashsale_process_worker_duration_seconds` (Worker, histogram) | Histogram quantiles | Exported |
| CPU, RAM per service | Process CPU seconds and memory | prometheus-net defaults: `process_cpu_seconds_total`, `process_working_set_bytes` | `rate()` / gauge | Exported |
| Host CPU, RAM | EC2 instance totals | Host monitoring | — | Week 13–14 |
| Database connections | Open PostgreSQL sessions per service account | `pg_stat_activity` grouped by `application_name` (each service sets its own) | Poll | Available; poller Week 13–14 |
| Redis latency | Time per Lua call | Redis `LATENCY` / `INFO commandstats` | Poll | Week 13–14 |
| RabbitMQ publish / deliver / ack rates | Broker message rates | RabbitMQ management API (`message_stats`) | Poll | Available; poller Week 13–14 |

## Exported Prometheus metrics, by service

| Service (scrape job) | Metric | Type | Labels |
|---|---|---|---|
| Order Service (`order-service`) | `flashsale_orders_accepted_total` | counter | — |
| | `flashsale_orders_outcome_total` | counter | `outcome` |
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
  `conflict` (a genuine state conflict).
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
