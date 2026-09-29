-- =====================================================
-- INVESTMENTS — allow a 'RECONCILIATION' source on investments_transactions
-- so system-generated reconciliation dummy trades can be distinguished from
-- real broker trades ('STATEMENT') and manual entries ('MANUAL') at read
-- time, without needing to re-derive their fingerprint.
-- =====================================================

ALTER TABLE investments_transactions
    DROP CONSTRAINT investments_transactions_source_check;

ALTER TABLE investments_transactions
    ADD CONSTRAINT investments_transactions_source_check
    CHECK (source IN ('STATEMENT', 'MANUAL', 'RECONCILIATION'));
