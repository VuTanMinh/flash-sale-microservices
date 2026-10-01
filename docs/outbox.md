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

A row may be marked `Published` only after the broker has **confirmed** the message **and routed it to at least one queue**. Unroutable messages (no matching binding) must not count as published. Box 2 specifies this in detail.
