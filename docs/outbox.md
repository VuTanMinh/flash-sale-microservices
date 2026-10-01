# Transactional Outbox and publication (Week 6)

Requirements: `docs/teacher-brief.md` §2a and §5 ("ghi event OrderPlaced vào Transactional Outbox trong cùng một database transaction", "Outbox Publisher tiếp tục retry cho đến khi RabbitMQ xác nhận message đã được nhận", "publisher confirm"). Tested by `scripts/verify-outbox.ps1` (TP-O01) and `scripts/verify-publication.ps1` (TP-O02).

## Atomic commit and rollback (TP-O01)

| Rule | Mechanism |
|---|---|
| An order and its `OrderPlaced` Outbox row commit together | Both are added to one `DbContext` and saved by one `SaveChangesAsync` (`OrdersController.CreateOrderAsync`) |
| If either insert fails, neither exists | One PostgreSQL transaction; the request fails with 5xx and leaves no order row and no Outbox row |
| The Outbox row starts unpublished | `Published = false`, `PublishedAt = null` |

## Stable MessageId on retry (TP-O01)

The event's `MessageId` is generated **once**, when the Outbox row is written (`OutboxEvent.ForOrderPlaced`), and stored inside `Payload`. The publisher (`OutboxPublisherWorker`) only ever sends the stored payload. A failed publish is retried with 1 s, 2 s and 4 s backoff, and then again on the next 2-second poll, forever, until the broker confirms. Every retry sends the same `MessageId`, so a consumer Inbox can drop a duplicate even if a confirm is lost after the broker accepted the message.

Not covered by this rule: the reconciliation job (Week 10) deliberately writes a *new* Outbox row with a *new* `MessageId` for an order stuck in `PendingStock`. Business-level idempotency (`OrderId`, Redis) absorbs that case. The TP-O01 test disables reconciliation so the two mechanisms are not confused.

## Routed confirmation (TP-O02, Week 6 box 2)

**Rule:** an Outbox row is marked `Published` only after the broker has **confirmed** the message **and routed it to every queue that must receive it**. Anything else leaves the row unpublished, so it is retried on the next 2-second poll.

**Found by the Week 6 code check (2026-10-01):** all three publishers used `mandatory: false`. A message with no matching binding was silently dropped by the broker, yet confirmed, and marked published. The prototype reproduced this: an `OrderPlaced` published before any queue was bound was marked published and reached nobody. The rule also needs more than `mandatory`: `StockReserved` must reach **two** queues (Order Service and the Process Worker). With only one bound, `mandatory` is satisfied while the Process Worker never sees the event.

**Mechanism** (all three publishers: Order Service and Inventory Service Outbox publishers, and the Process Worker's `OrderProcessedPublisher`):

1. The required subscriber queues per event type are configured in `RabbitMQ:EventBus:RequiredSubscriberQueues`:

   | Event | Required queues | Publisher |
   |---|---|---|
   | `OrderPlaced` | `OrderPlaced` | Order Service |
   | `StockReserved` | `StockReserved`, `ProcessWorker.StockReserved` | Inventory Service |
   | `StockRejected` | `StockRejected` | Inventory Service |
   | `OrderProcessed` | `OrderProcessed` | Process Worker |

   An event type with no entry is refused: the publisher never publishes unchecked.
2. Before each publish, every required queue is checked with a **passive declare**, which fails if the queue does not exist. It is then **bound** to the exchange with the event's routing key. Binding is idempotent, so a removed binding is restored instead of silently splitting subscribers. The consumer still owns the queue and its arguments; the publisher never creates a queue.
3. The message is published with `mandatory: true` on a channel with publisher confirmations and confirmation tracking. `BasicPublishAsync` throws `PublishException` if the broker **nacks** the message, or **returns** it as unroutable (`IsReturn = true`).
4. Any exception, including a missing queue, a nack, a return or a lost connection, leaves the row unpublished. The Outbox worker retries 1 s / 2 s / 4 s, then again every poll. Recovery is automatic once the cause is fixed.

| Failure | Outcome |
|---|---|
| Required queue does not exist (consumer not started yet) | Not published, retried; published as soon as the queue exists |
| Required binding removed | Binding restored by the publisher; delivered |
| Broker nacks (e.g. a full queue with `reject-publish`) | Not published, retried; published after space frees up |
| Message returned as unroutable | Not published, retried |
| Broker down or connection lost | Not published, retried; the connection is re-created on the next attempt |

For the Process Worker there is no Outbox. A failed `OrderProcessed` publish makes its `StockReserved` handling fail, so the message is retried and finally dead-lettered (Week 10) rather than lost.
