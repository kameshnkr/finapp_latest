-- =====================================================
-- Migration: Budget Reset Logic
-- Replaces the old dummy `schedule` TEXT column with proper
-- reset_type / reset_schedule / period_start / period_end columns
-- and adds the budget_snapshots table.
--
-- Safe to run once on an existing database.
-- All existing budgets are migrated to reset_type = 'manual'.
-- =====================================================

BEGIN;

-- 1. Add new reset columns to budgets
ALTER TABLE budgets
    ADD COLUMN reset_type     TEXT NOT NULL DEFAULT 'manual'
                                  CHECK (reset_type IN ('scheduled', 'manual')),
    ADD COLUMN reset_schedule JSONB,
    ADD COLUMN period_start   TIMESTAMPTZ,
    ADD COLUMN period_end     TIMESTAMPTZ;

-- 2. Drop the old dummy schedule column
ALTER TABLE budgets DROP COLUMN schedule;

-- 3. Create budget_snapshots table
CREATE TABLE budget_snapshots (
    id              BIGINT PRIMARY KEY,
    budget_id       BIGINT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,

    estimated       NUMERIC(14,2) NOT NULL,
    spent           NUMERIC(14,2) NOT NULL,
    funds_available NUMERIC(14,2) NOT NULL,

    period_start    TIMESTAMPTZ,
    period_end      TIMESTAMPTZ,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_budget_snapshots_budget ON budget_snapshots(budget_id);

COMMIT;
