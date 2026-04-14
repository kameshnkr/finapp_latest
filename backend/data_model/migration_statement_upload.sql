-- =====================================================
-- STATEMENT UPLOAD FEATURE
-- =====================================================

-- Actual date of a transaction as it appears in the bank statement.
-- NULL for manual transactions.
ALTER TABLE transactions
    ADD COLUMN transaction_date DATE;

-- SHA-256 fingerprint for deduplication of statement-imported transactions.
-- Computed from: account_id | date | amount | normalized_description | type
-- NULL for manual transactions.
ALTER TABLE transactions
    ADD COLUMN fingerprint TEXT;

-- Partial unique index — only enforces uniqueness for statement transactions.
CREATE UNIQUE INDEX idx_tx_fingerprint
    ON transactions(fingerprint)
    WHERE fingerprint IS NOT NULL;

-- =====================================================
-- STATEMENT JOBS
-- Tracks async PDF processing pipeline state.
-- =====================================================
CREATE TABLE statement_jobs (
    id              TEXT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,

    status          TEXT NOT NULL DEFAULT 'UPLOADING'
                        CHECK (status IN ('UPLOADING', 'PROCESSING', 'VALIDATING', 'SAVING', 'COMPLETED', 'FAILED')),

    -- Human-readable stage message for frontend progress display
    stage_message   TEXT,

    -- JSON result on completion: { total_extracted, total_inserted, duplicates_skipped, validation_status }
    result          JSONB,

    -- Set on FAILED
    error_message   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_statement_jobs_user ON statement_jobs(user_id);
