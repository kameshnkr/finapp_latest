-- =====================================================
-- Migration: Switch pagination indexes to effective date
--
-- Effective date = COALESCE(transaction_date, created_at::date)
--   • transaction_date is the real bank date (statement imports)
--   • falls back to created_at date for manual transactions
--
-- Both date-range filtering and ordering now use this field.
-- =====================================================

BEGIN;

-- Drop the timestamp-based indexes added in the previous migration
DROP INDEX IF EXISTS idx_tx_drafts_pagination;
DROP INDEX IF EXISTS idx_tx_settled_pagination;

-- Drafts: expression index on effective date + id
CREATE INDEX idx_tx_drafts_pagination
  ON transactions(user_id, COALESCE(transaction_date, created_at::date) DESC, id DESC)
  WHERE status = 'draft';

-- Settled: same expression
CREATE INDEX idx_tx_settled_pagination
  ON transactions(user_id, COALESCE(transaction_date, created_at::date) DESC, id DESC)
  WHERE status = 'settled';

COMMIT;
