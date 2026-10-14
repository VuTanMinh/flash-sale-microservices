-- KEYS[1] = inventory key           (e.g. "inventory:{productId}")
-- KEYS[2] = processed-orders set key (e.g. "processed:{productId}")
-- KEYS[3] = sale-open marker         (e.g. "sale:open:{productId}"; set only by a confirmed warm-up)
-- ARGV[1] = order_id
-- Runs atomically. Order of checks: duplicate first (a redelivered order that
-- already holds a unit is still answered DUPLICATE), then readiness, then stock.
-- See docs/inventory.md.
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
  return 'DUPLICATE'
end
if redis.call('EXISTS', KEYS[3]) == 0 then
  return 'NOT_OPEN'
end
local stock = tonumber(redis.call('GET', KEYS[1]))
if stock == nil or stock <= 0 then
  return 'REJECTED'
end
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
return 'RESERVED'
