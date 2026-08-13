-- Known starting inventory state, run after scripts/reset.sql before every
-- experiment (JMeter smoke/load tests, manual C0/C1 verification, etc.) so
-- results are comparable across runs. Idempotent.
INSERT INTO order_service.inventory (product_id, stock) VALUES
    ('flash-product-1', 1000),   -- general-purpose product for JMeter smoke/load tests (Step 3.5+)
    ('c0-demo-product', 1),      -- matches C0NaiveDemo's own product id (Experiments/C0Naive)
    ('c1-demo-product', 1)       -- for re-running the manual C1 concurrency check (Step 3.3)
ON CONFLICT (product_id) DO UPDATE SET stock = EXCLUDED.stock;
