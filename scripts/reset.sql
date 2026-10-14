-- Truncates baseline experiment state. Idempotent — safe to run repeatedly.
-- Assumes scripts/schema/baseline-schema.sql has already been applied once
-- (this script only empties tables, it doesn't create them).
TRUNCATE TABLE order_service.baseline_orders;
TRUNCATE TABLE order_service.inventory;
