# Requirement-to-evidence index

Generated from `docs/test-plan.md` and the logs in `tests/evidence/`. For each
requirement of the brief (`docs/teacher-brief.md` §4), the test cases that cover
it, their status, and two log paths: the evidence the test plan names, and the
latest saved run of the same verifier. The test plan holds the inputs, expected
results and negative controls of each case.

Kinds of evidence: **offline** checks read code, documents and configuration;
**application** tests run the services on throwaway containers on the
development PC; **live** evidence comes from the EC2 sessions (TP-L03, and the EC2
half of TP-L04, which ran on the code from before the review and whose raw data
was not archived).

| Requirement | Case | Status | Evidence named in the test plan | Latest run |
|---|---|---|---|---|
| Accept and store an order, return its ID, poll its status; one order per Idempotency-Key | TP-A01 | PASS | `tests/evidence/20261001T123317Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
|  | TP-A02 | PASS | `tests/evidence/20261001T123317Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
|  | TP-A03 | PASS | `tests/evidence/20261001T123317Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
|  | TP-A04 | PASS | `tests/evidence/20261001T123317Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
|  | TP-A05 | PASS | `tests/evidence/20261001T123317Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
|  | TP-A07 | PASS | `tests/evidence/20261001T123816Z-order-api.log` | `tests/evidence/20261013T145229Z-order-api.log` |
| Order state machine (six states) and transitions | TP-A06 | PASS | `tests/evidence/20261001T123816Z-unit-tests.trx` | — |
|  | TP-P02 | PASS | `tests/evidence/20261013T145229Z-processing.log` | `tests/evidence/20261024T081721Z-processing.log` |
|  | TP-E03 | PASS | `tests/evidence/20261024T084347Z-unit-tests.log` | — |
| Reserve inventory atomically; stock never negative, never above initial stock, one reservation per order | TP-B01 | PASS | `tests/baseline/results/20261001T112439Z-c0-race.json` | — |
|  | TP-B02 | PASS | `tests/baseline/results/20261001T112439Z-summary.md` | — |
|  | TP-I01 | PASS | `tests/evidence/20261002T051418Z-inventory.log` | `tests/evidence/20261024T082310Z-inventory.log` |
|  | TP-I02 | PASS | `tests/evidence/20261002T051418Z-inventory.log` | `tests/evidence/20261024T082310Z-inventory.log` |
|  | TP-I03 | PASS | `tests/evidence/20261002T052244Z-cross-store.log` | `tests/evidence/20261024T082358Z-cross-store.log` |
|  | TP-W02 | PASS | `tests/evidence/20261002T062442Z-validator.log` | `tests/evidence/20261024T082949Z-validator.log`, `tests/evidence/20261024T082913Z-real-runs.log` |
| Update order status from the stock result | TP-W01 | PASS | `tests/evidence/20261002T061249Z-stock-results.log` | `tests/evidence/20261024T082221Z-stock-results.log` |
|  | TP-W03 | PASS | `tests/evidence/20261002T063611Z-db-exceptions.log` | `tests/evidence/20261024T082450Z-db-exceptions.log` |
|  | TP-W04 | PASS | `tests/evidence/20261002T152659Z-workflow.log` | `tests/evidence/20261024T083306Z-workflow.log` |
| Transactional Outbox at the producer; publisher confirms and routing | TP-O01 | PASS | `tests/evidence/20261024T083744Z-outbox.log` | `tests/evidence/20261024T083744Z-outbox.log` |
|  | TP-O02 | PASS | `tests/evidence/20261001T163055Z-publication.log` | `tests/evidence/20261024T081509Z-publication.log` |
| Inbox at the consumer; duplicates and crashes have no second effect | TP-M01 | PASS | `tests/evidence/20261024T083445Z-delivery.log` | `tests/evidence/20261024T083445Z-delivery.log` |
|  | TP-M02 | PASS | `tests/evidence/20261003T181814Z-delivery-ordering.log` | `tests/evidence/20261024T080738Z-delivery-ordering.log` |
| Retry transient failures; poison messages to a DLQ | TP-F01 | PASS | `tests/evidence/20261011T122332Z-failures.log` | `tests/evidence/20261024T080947Z-failures.log` |
| Reconciliation job for stuck orders | TP-F02 | PASS | `tests/evidence/20261023T160450Z-reconciliation.log` | `tests/evidence/20261024T075611Z-reconciliation.log` |
| Simulated downstream processing (deterministic Worker) | TP-P01 | PASS | `tests/evidence/20261024T083825Z-worker.log` | `tests/evidence/20261024T083825Z-worker.log` |
| Trace each order: correlation, order and message IDs, history, four timestamps | TP-P03 | PASS | `tests/evidence/20261013T163219Z-trace.log` | — |
|  | TP-P06 | PASS | `tests/evidence/20261014T140055Z-message-timestamps.log` | `tests/evidence/20261024T082700Z-message-timestamps.log` |
| Metrics, run-time collection and extraction | TP-P04 | PASS | `tests/evidence/20261013T163454Z-metrics.log` | `tests/evidence/20261024T082532Z-metrics.log` |
|  | TP-P07 | PASS | `tests/evidence/20261024T074956Z-run-collector.log` | `tests/evidence/20261024T074956Z-run-collector.log` |
|  | TP-P08 | PASS | `tests/evidence/20261024T073819Z-extract.log` | `tests/evidence/20261024T073819Z-extract.log` |
| Controlled rejection under overload; backlog drains without a restart | TP-L01 | PASS | `tests/evidence/20261019T161529Z-load-shedding.log` | `tests/evidence/20261024T080008Z-load-shedding.log` |
|  | TP-L02 | PASS | `tests/evidence/20261020T030050Z-load-shedding.log` | `tests/evidence/20261024T080008Z-load-shedding.log` |
|  | TP-L04 | PASS | `tests/evidence/20261023T160859Z-load-shedding.log` | `tests/evidence/20261024T080008Z-load-shedding.log`, `tests/evidence/20261022T093449Z-ec2-deployment.log` |
| Schema per service, own database accounts | TP-E01 | PASS | `tests/evidence/20261001T114318Z-environment-fresh.log` | `tests/evidence/20261013T145229Z-environment.log` |
|  | TP-E02 | PASS | `tests/evidence/20261001T114318Z-environment-existing.log` | `tests/evidence/20261013T145229Z-environment.log` |
|  | TP-E04 | PASS | `tests/evidence/20261023T173539Z-runtime-accounts.log` | `tests/evidence/20261023T173539Z-runtime-accounts.log` |
| Terraform, AWS EC2 backend, separate JMeter host | TP-L03 | PASS | `tests/evidence/20261024T084414Z-deployment-offline.log` | `tests/evidence/20261022T093449Z-ec2-deployment.log` |
| Repeated experiments C0-C4, README reproduction | TP-X01 | NOT RUN | — | — |
|  | TP-X02 | NOT RUN | — | — |
|  | TP-X03 | NOT RUN | — | — |

## Not covered by a saved run

- Raw data of the Week 12 EC2 overload run (JTL, collector samples): lost with
  the instances; only `tests/evidence/20261022T163505Z-ec2-overload.log` (console
  summary) exists. It is not reconstructed.
- The EC2 changes of the midterm review's second pass (Worker metrics address,
  queue policy and collector through `docker exec`) were verified locally only.
- TP-X01–X03 belong to Weeks 13–14.
