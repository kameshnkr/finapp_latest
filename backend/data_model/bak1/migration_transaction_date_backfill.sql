-- =====================================================
-- Migration: Backfill transaction_date + effective-date indexes
--
-- 1. Backfill transaction_date for existing manual transactions
--    (new inserts already set it via CURRENT_DATE in insertDraft).
--
-- 2. Drop timestamp-based pagination indexes and replace with
--    expression indexes on COALESCE(transaction_date, created_at::date).
--    Uses IF NOT EXISTS / IF EXISTS so the script is safe to re-run.
-- =====================================================

BEGIN;

-- Backfill: set transaction_date = created_at::date for every manual
-- transaction that currently has NULL. Idempotent — no-op if already done.
UPDATE transactions
   SET transaction_date = created_at::date
 WHERE transaction_date IS NULL
   AND source = 'manual';

-- Drop old timestamp-based indexes (both the original and any partial replacement)
DROP INDEX IF EXISTS idx_tx_drafts_pagination;
DROP INDEX IF EXISTS idx_tx_settled_pagination;

-- Simple column indexes — transaction_date is now always populated after backfill
CREATE INDEX IF NOT EXISTS idx_tx_drafts_pagination
  ON transactions(user_id, transaction_date DESC, id DESC)
  WHERE status = 'draft';

CREATE INDEX IF NOT EXISTS idx_tx_settled_pagination
  ON transactions(user_id, transaction_date DESC, id DESC)
  WHERE status = 'settled';

COMMIT;
