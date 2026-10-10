# Study guide (owner's reference, summarised)

Source: "Flash Sale Microservices Study Guide", prepared for Vũ Tấn Minh
(523V0012), 7 October 2026. The owner gave it on 2026-10-10 to be kept with
this skill.

The guide's own disclaimer: its state names, API shapes, schemas and code are
teaching examples, not claims about this repository. Use it as the knowledge
standard to hold work to. The plan is still Notion 05 (with 03), and the code
and evidence are still the truth.

**How to use it:** before each box's code check, read the chapter for that
topic. Ask its three questions of the change:
1. What if two operations run at the same time?
2. What if a message or request arrives twice?
3. What if a process crashes here?

Work is understood when you can predict the stored state and the next
recovery action.

## Chapter map and the points to enforce

**1. Purpose and correctness rules**
- Correctness first; requests per second alone proves nothing.
- Invariants: stock is never negative, there is one reservation per order, a
  request id maps to one operation, and terminal failures are observable.
- Conservation: initial stock = available + active reserved + completed sold,
  where the categories are mutually exclusive.
- Accepted is not the same as reserved or completed. Report accepted,
  reserved, completed, rejected and unfinished separately.

**2. Backend and microservices**
- Each service owns its data. Order Service never writes Inventory tables.
- A timeout means "unknown", not "failed".
- Eventual consistency must not mean lost work. A permanently pending order
  with no retry or reconciliation path is a defect.

**3. Concurrency and transactions**
- A race can oversell without stock ever going negative.
- A mutex in one process does not protect several containers.
- A PostgreSQL transaction cannot include Redis or RabbitMQ.
- The C1 pattern is a guarded `UPDATE ... WHERE stock >= qty` plus the order
  insert, in one transaction.
- Retry deadlocks and serialization failures with a bound. Constraints are
  the second line of defence.

**4. API contracts and order state**
- Validate before any Redis or SQL work.
- Answer "accepted" only after the order and its Outbox row have committed.
- Guarded transitions: a repeated event leaves the state unchanged, and
  out-of-order events need a documented policy.
- Event id stays stable on republish. A delivery tag is never a
  deduplication key.

**5. RabbitMQ and delivery**
- Publisher confirms and consumer acks are different things.
- Ack manually, after the durable effect. Acking before the commit can lose
  work; acking after it can only produce a duplicate.
- An exchange accepting a message does not mean a queue received it; handle
  unroutable messages.
- Delivery is at-least-once. Multiple consumers can reorder completion.

**6. Idempotency and the Inbox**
- Repeating an operation must not repeat its effect.
- Request keys: unique constraint plus a payload fingerprint; the same key
  with a different payload is rejected.
- The Inbox row, the business change and the result Outbox row commit
  together.
- Deduplicate by event id and also enforce business uniqueness by order id.
- Concurrent duplicates are decided by the database or an atomic operation,
  never by an in-memory set.

**7. Transactional Outbox**
- Dual writes are unsafe in either order.
- The relay publishes, waits for the confirm, then marks the row sent, so
  duplicates are still possible and consumers must be idempotent.
- Bounded batches; track the age of the oldest pending row.
- Apply the Outbox at every service boundary.

**8. Redis reservation and recovery**
- Lua is atomic against interleaving, but it is not a transaction with
  PostgreSQL and does not roll back on a script error.
- In the Redis-then-SQL gap, redelivery must reuse the reservation and
  complete the SQL work.
- Never let deduplication records expire before a replay could arrive.
- Releasing a reservation must be idempotent.
- Persistence settings change the loss window; they do not close the gap.

**9. Retries, compensation and failure analysis (Week 10)**
- **Classify before retrying.** Transient (a brief database outage) is
  retried. Permanent (an invalid message or version) is not. Sold out is a
  business decision, not a retry. A timeout has an unknown outcome, so a
  retry needs the original identity.
- **Bounded retries:** exponential backoff with a cap, and jitter where
  appropriate. Set a maximum number of attempts or a time budget. Never loop
  on immediate requeue. After the limit, dead-letter the message with enough
  information to diagnose it.
- **A DLQ does not repair anything.** It needs an owner, an alert, an
  inspection procedure and a controlled replay that keeps the event id. If
  the payload is corrected, decide whether it is the same operation or a new
  version, and keep audit evidence.
- **Compensation** is a new business action that reverses an earlier one. It
  must itself be idempotent, and a release racing a completion needs guarded
  transitions.
- **Failure matrix:**

  | Crash point | Defence |
  |---|---|
  | Before the accept commit | Retry with the same key |
  | After commit, before the HTTP reply | The retry returns the same order |
  | After publish, before the Outbox row is marked sent | Consumer deduplication |
  | After Redis, before the SQL result | Reuse the reservation and reconcile |
  | After the SQL effect, before the ack | Inbox plus business uniqueness |
  | After the ack, before the effect | Prevented by correct ack timing |
  | Redis data loss | A defined rebuild and admission policy |

- **Observability:** every log carries order id, event id, correlation id,
  service, operation, attempt and outcome. Metrics include pending Outbox age
  and reconciliation failures.
- **Incident order:**
  1. the order;
  2. its Outbox row;
  3. routing and the queue;
  4. the Inbox and the reservation;
  5. retries and the DLQ;
  6. the earliest missing transition.

  Never delete queues or reset stock first.

**10. Docker, deployment and security**
- A started container is not a ready one: use readiness checks.
- Pin versions, keep secrets out of git, and use least-privilege database
  users.
- Do not expose PostgreSQL, Redis or RabbitMQ publicly.
- One EC2 host is one failure domain.
- Terraform state can hold secrets. Never commit credentials.

**11. Performance and experiments**
- Request throughput is not completion throughput; acceptance latency is not
  end-to-end latency.
- p95 is not an average, and percentiles are never averaged across runs.
- Report backlog and recovery, and do not end a test while accepted work
  remains.
- Admission control rejections are counted separately from failures.
- Configurations: C0 (unsafe race), C1 (synchronous PostgreSQL), C2 (RabbitMQ
  and Redis), C3 (C2 plus admission control), C4 (1, 2 and 4 Inventory
  consumers).
- Comparisons must be fair: same hardware, fresh seed, same workload, fixed
  versions, warm-up, repeats.
- Run JMeter in non-GUI mode, measure the achieved arrival rate, and keep the
  raw data.

**12. Implementation stages**
- Stages: C0, then C1, then states and contracts, then the Outbox and
  consumers, then the Inbox, then Redis recovery, then the Worker, retry and
  DLQ, then metrics and admission, then deployment and experiments.
- Never postpone correctness.
- Exercise 6 is Week 10's test: a transient dependency failure, then an
  invalid message. They must take different retry paths, the DLQ outcome must
  be visible, and a safe replay must follow after the fix.

**13. Oral exam:** the guide's model answers cover:
- the purpose of the DLQ, which is to isolate work the retry policy cannot
  handle, for inspection and a deliberate replay;
- ack timing;
- that exactly-once is not claimed, only one business effect within the
  stated assumptions;
- why four consumers can be slower than one;
- why HTTP 202 latency is not comparable with C1.

**14. Readiness checklists**
- Retries are bounded, and DLQ work has a documented resolution path.
- Injected crash tests cover every cross-component boundary.
- Metrics separate completion, rejection, timeout and unfinished work.
- Conclusions match the saved raw data.
