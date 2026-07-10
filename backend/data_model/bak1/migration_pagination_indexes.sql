-- =====================================================
-- Migration: Cursor-based pagination indexes
-- Replaces idx_tx_user_settled with purpose-built
-- partial indexes for drafts and settled pagination.
-- =====================================================

BEGIN;

-- Drop the old index that is superseded by the new settled partial index
DROP INDEX IF EXISTS idx_tx_user_settled;

-- Drafts: covers user filter + date-range bounds + cursor comparison + sort.
-- Partial index (WHERE status = 'draft') keeps it small and lets the planner
-- skip the status predicate entirely.
CREATE INDEX idx_tx_drafts_pagination
  ON transactions(user_id, created_at DESC, id DESC)
  WHERE status = 'draft';

-- Settled: same structure for settled transactions.
-- settled_at is always non-null on settled rows (set in settleTransactions()).
CREATE INDEX idx_tx_settled_pagination
  ON transactions(user_id, settled_at DESC NULLS LAST, id DESC)
  WHERE status = 'settled';

-- idx_tx_user_status is retained: used by lockTransactionsForUser and other
-- queries that filter by (user_id, status) without date-range sorting.

COMMIT;
