-- C0/C1 baseline experiment tables (Week 3).
--
-- These are deliberately NOT part of the EF Core-migrated domain model in
-- src/FlashSale.OrderService/Migrations/ — C0 and C1 are controlled baseline
-- configurations, not the final design (that's the async, Redis/RabbitMQ-based
-- system built Weeks 5-11 per docs/erd.md). Keeping them as plain raw-SQL
-- tables in their own namespace makes that distinction explicit: nothing here
-- should end up looking like it's part of the real Order/OutboxEvent/
-- ProcessedMessage schema docs/erd.md describes.
--
-- Idempotent: safe to run repeatedly (used by scripts/reset-and-seed.ps1).

CREATE SCHEMA IF NOT EXISTS order_service;

-- No CHECK (stock >= 0) here on purpose: C0 (Step 3.2) needs to be able to
-- push this negative to demonstrate over-selling cleanly, and a constraint
-- that blocked that would just turn the bug into an unhandled exception
-- instead of the actual failure the checklist wants captured as evidence.
-- C1 (Step 3.3) never triggers this path — its own WHERE stock >= 1 keeps it
-- non-negative by construction, not by a DB-level constraint.
CREATE TABLE IF NOT EXISTS order_service.inventory (
    product_id TEXT PRIMARY KEY,
    stock INTEGER NOT NULL
);

-- Logs every C0/C1 attempt outcome — this is the "camera/log evidence" Step 3.2
-- asks for, and what Step 3.3's manual verification queries against.
CREATE TABLE IF NOT EXISTS order_service.baseline_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config TEXT NOT NULL CHECK (config IN ('C0', 'C1')),
    product_id TEXT NOT NULL,
    result TEXT NOT NULL CHECK (result IN ('Confirmed', 'Rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Order Service's C0/C1 code connects as order_service_user, so it must own
-- these tables. This script runs as the flashsale admin account, which would
-- otherwise own them and leave the service with no privileges at all. Same
-- owner as the existing-database path in infra/initdb/01-create-service-roles.sql.
ALTER TABLE order_service.inventory OWNER TO order_service_user;
ALTER TABLE order_service.baseline_orders OWNER TO order_service_user;
