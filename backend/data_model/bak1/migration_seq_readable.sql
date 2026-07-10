-- Migration: Add statement_seq and description_readable to transactions
-- statement_seq: preserves the LLM's statement order for same-date transactions
-- description_readable: human-friendly description stripped of IDs/codes

BEGIN;

ALTER TABLE transactions
  ADD COLUMN IF NOT EXISTS statement_seq       INTEGER,
  ADD COLUMN IF NOT EXISTS description_readable TEXT;

-- Index to speed up ORDER BY transaction_date DESC, statement_seq DESC NULLS LAST on drafts
CREATE INDEX IF NOT EXISTS idx_tx_date_seq
  ON transactions (transaction_date DESC, statement_seq DESC NULLS LAST)
  WHERE status = 'draft';

COMMIT;
