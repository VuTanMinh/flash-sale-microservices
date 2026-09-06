-- KEYS[1] = inventory key (e.g. "inventory:{productId}")
-- KEYS[2] = processed-orders set key (e.g. "processed:{productId}")
-- ARGV[1] = order_id
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then
  return 'DUPLICATE'
end
local stock = tonumber(redis.call('GET', KEYS[1]))
if stock == nil or stock <= 0 then
  return 'REJECTED'
end
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
return 'RESERVED'
