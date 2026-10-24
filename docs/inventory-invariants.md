# Inventory Invariants and Acceptance Checks

These rules apply to C1–C4. C0 is deliberately unsafe and exists only to demonstrate the race condition.

1. **No negative stock.** For every product, `available_inventory >= 0` at all times.
2. **No oversell.** For each product and clean experiment run, successful reservations are no greater than the seeded initial stock.
3. **One reservation per order.** A repeated request or redelivered event for the same order can cause at most one stock decrement.
4. **Inbox idempotency.** Re-delivery of the same broker `MessageId` does not apply the business effect twice. This is separate from Redis reservation deduplication by `OrderId` and HTTP idempotency by client key.
5. **No silent loss after acceptance.** Each accepted order reaches `Completed` or `Rejected`, or is surfaced by reconciliation/DLQ evidence. A passing stock check alone does not satisfy this liveness check.
6. **One downstream completion.** Duplicate `StockReserved` delivery must not create more than one effective completion for an order.

## Evidence required per run

- Record the stock value and reservation-set cardinality immediately after seed/warm-up and after the workload. For the Redis-backed path, compare the stock delta with the number of unique order IDs in `processed:{productId}`; investigate any mismatch.
- For C1, count `Confirmed` results in the baseline result table and compare with the initial stock. Keep C0 results separate because it is intentionally racy.
- Query order states, Outbox/Inbox rows, retry attempts, DLQs, and reconciliation results. Reconcile accepted requests against terminal orders plus explicitly surfaced exceptions.
- Replay the same event and the same order under a different message ID. Verify broker-message deduplication and reservation-level deduplication independently.

The correctness validator must take product IDs and initial stock as inputs, fail on unavailable database/Redis/query errors, and exit nonzero for every violated rule. Empty results, missing keys, and skipped checks must never be reported as a pass.
