# Inventory reservation (Week 7)

Requirements: `docs/teacher-brief.md` §2b (atomic idempotency check, stock check, decrement, record; invariants), §5 "Inventory Warm-up" ("Sản phẩm chỉ được mở bán sau khi warm-up hoàn tất và được xác nhận"). Tested by `scripts/verify-inventory.ps1` (TP-I01, TP-I02) and `scripts/verify-cross-store.ps1` (TP-I03).

## Redis keys (owned by Inventory Service)

| Key | Type | Meaning |
|---|---|---|
| `inventory:{productId}` | string (integer) | Units still available |
| `processed:{productId}` | set | Order ids that already hold a reservation for this product |
| `sale:open:{productId}` | string | Present only after warm-up completed and was confirmed; the sale is open |

## Warm-up and readiness (TP-I01)

`scripts/warm-up.ps1` loads each product in **one atomic step** (a Lua `EVAL`). It sets `inventory:{productId}` to the initial stock, deletes `processed:{productId}`, and sets `sale:open:{productId}`. It then **confirms** each product by reading the keys back: stock equals the requested value, the processed set is empty, and the open marker exists. It reports `CONFIRMED` per product and exits non-zero if any product does not confirm.

- **Before warm-up, nothing can be reserved.** `reserve.lua` answers `NOT_OPEN` when `sale:open:{productId}` is missing. Inventory Service publishes `StockRejected` and logs the reason, so the order is not left waiting and no stock is touched. Before this change, an un-warmed product was answered `REJECTED`, exactly like a sold-out product, and nothing recorded whether warm-up had happened.
- **Re-running warm-up during a sale is refused.** It would reset stock and forget reservations. `-Force` is needed to reset an open product, and is meant for experiment resets only.

## Reservation script (`scripts/redis/reserve.lua`)

Runs atomically in Redis (one `EVAL`; no other command interleaves):

1. If the order id is in `processed:{productId}`, return `DUPLICATE` (no change).
2. If `sale:open:{productId}` is missing, return `NOT_OPEN` (no change).
3. If the stock is missing or ≤ 0, return `REJECTED` (no change).
4. Otherwise `DECR` the stock, `SADD` the order id, and return `RESERVED`.

Inventory Service maps `RESERVED` and `DUPLICATE` to `StockReserved`, and `REJECTED` and `NOT_OPEN` to `StockRejected`. The duplicate check comes first, so a redelivered order that already holds a reservation is still answered `StockReserved` (`docs/design-decisions.md` §4).

## Per-product invariants (TP-I02)

For every product, after any amount of concurrent traffic:

1. `inventory ≥ 0`
2. reservations (`SCARD processed`) ≤ initial stock
3. `inventory + SCARD processed = initial stock` (stock is conserved: every unit is either available or held by exactly one order)
4. each order id appears at most once in `processed` (set semantics), and a repeated order id gets `DUPLICATE`, never a second unit

They are checked against Redis after a burst of concurrent requests on one hot product and on several products with a skewed distribution.
