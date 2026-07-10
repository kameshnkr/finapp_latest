-- =====================================================
-- USERS
-- =====================================================
CREATE TABLE users (
    id              BIGINT PRIMARY KEY,
    email           TEXT UNIQUE NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================
-- SESSIONS (persistent login)
-- =====================================================
CREATE TABLE sessions (
    id              BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token           TEXT NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sessions_user ON sessions(user_id);

-- =====================================================
-- ACCOUNTS (Source of money)
-- =====================================================
CREATE TABLE accounts (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    total_balance       NUMERIC(14,2) NOT NULL,
    description         TEXT,
    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_user ON accounts(user_id);

-- =====================================================
-- ACCOUNTS DISPLAY ORDER (per user)
-- =====================================================
CREATE TABLE accounts_display_order (
    user_id         BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_order   JSONB NOT NULL
);

-- =====================================================
-- BUDGETS (Purpose of money)
-- =====================================================
CREATE TABLE budgets (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,

    -- Reset behaviour
    reset_type          TEXT NOT NULL DEFAULT 'manual'
                            CHECK (reset_type IN ('scheduled', 'manual')),
    -- JSON: { type: 'every_month_on_date', date: 1-28 | null, is_last_day_of_month: bool }
    -- null for manual budgets
    reset_schedule      JSONB,

    -- Active period boundaries (UTC). end_timestamp is EXCLUSIVE.
    -- Both null for manual budgets.
    period_start        TIMESTAMPTZ,
    period_end          TIMESTAMPTZ,

    -- spent is the only stored aggregate; estimated and funds_available are
    -- derived at read time (from budget_categories and account_budget_allocations).
    spent               NUMERIC(14,2) NOT NULL DEFAULT 0,

    category_order      JSONB NOT NULL DEFAULT '[]',
    version             INT NOT NULL DEFAULT 1,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_budgets_user ON budgets(user_id);

-- =====================================================
-- BUDGET PERIOD SNAPSHOTS
-- Captures the state of a budget at the end of each completed period.
-- Inserted only when a scheduled reset successfully fires (idempotent guard).
-- =====================================================
CREATE TABLE budget_snapshots (
    id              BIGINT PRIMARY KEY,
    budget_id       BIGINT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,

    estimated       NUMERIC(14,2) NOT NULL,
    spent           NUMERIC(14,2) NOT NULL,
    funds_available NUMERIC(14,2) NOT NULL,

    -- The period that just ended (matches the old period_start / period_end)
    period_start    TIMESTAMPTZ,
    period_end      TIMESTAMPTZ,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_budget_snapshots_budget ON budget_snapshots(budget_id);

-- =====================================================
-- BUDGET CATEGORIES
-- =====================================================
CREATE TABLE budget_categories (
    id              BIGINT PRIMARY KEY,
    budget_id       BIGINT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,

    name            TEXT NOT NULL,
    estimated       NUMERIC(14,2) NOT NULL,
    spent           NUMERIC(14,2) NOT NULL DEFAULT 0,
    remaining       NUMERIC(14,2) NOT NULL,

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_budget_categories_budget ON budget_categories(budget_id);

-- =====================================================
-- ACCOUNT ↔ BUDGET ALLOCATIONS
-- =====================================================
CREATE TABLE account_budget_allocations (
    id              BIGINT PRIMARY KEY,
    account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    budget_id       BIGINT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,

    amount          NUMERIC(14,2) NOT NULL,

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, budget_id)
);

CREATE INDEX idx_aba_account ON account_budget_allocations(account_id);
CREATE INDEX idx_aba_budget ON account_budget_allocations(budget_id);

-- =====================================================
-- TRANSACTIONS (Draft + Settled)
-- =====================================================
CREATE TABLE transactions (
    id              BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    budget_id       BIGINT REFERENCES budgets(id) ON DELETE SET NULL,
    category_id     BIGINT REFERENCES budget_categories(id) ON DELETE SET NULL,

    direction       TEXT NOT NULL CHECK (direction IN ('credit', 'debit')),
    amount          NUMERIC(14,2) NOT NULL,

    status          TEXT NOT NULL CHECK (status IN ('draft', 'settled')),
    source          TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'gmail', 'statement')),

    transaction_type TEXT CHECK (transaction_type IN ('expense', 'expense_refund', 'transfer', 'balance_adjustment')),

    -- Raw description as it appears in bank statement (statement imports only)
    description         TEXT,
    -- Human-friendly label extracted by LLM, e.g. "Meridian Restaurant" (statement imports only)
    description_readable TEXT,
    note                TEXT,

    settled_at      TIMESTAMPTZ,

    -- Actual bank date from statement; set to CURRENT_DATE for manual inserts.
    -- Always populated after the backfill migration.
    transaction_date    DATE,

    -- SHA-256 fingerprint for statement deduplication:
    -- hash(account_id | date | amount | normalized_description | type)
    -- NULL for manual transactions.
    fingerprint         TEXT,

    -- Position of this transaction within the LLM output for the same date (0-based).
    -- NULL for manual transactions. Used for stable within-date ordering.
    statement_seq       INTEGER,

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- General filter index (used by lockTransactionsForUser and non-paginated queries)
CREATE INDEX idx_tx_user_status ON transactions(user_id, status);

-- Pagination indexes: ordering by transaction_date + id for both draft and settled
CREATE INDEX idx_tx_drafts_pagination
    ON transactions(user_id, transaction_date DESC, id DESC)
    WHERE status = 'draft';

CREATE INDEX idx_tx_settled_pagination
    ON transactions(user_id, transaction_date DESC, id DESC)
    WHERE status = 'settled';

-- Deduplication: unique fingerprint for statement-imported transactions only
CREATE UNIQUE INDEX idx_tx_fingerprint
    ON transactions(fingerprint)
    WHERE fingerprint IS NOT NULL;

-- Within-date ordering for statement transactions on the drafts list
CREATE INDEX idx_tx_date_seq
    ON transactions(transaction_date DESC, statement_seq DESC NULLS LAST)
    WHERE status = 'draft';

-- =====================================================
-- STATEMENT JOBS
-- Tracks async PDF processing pipeline state.
-- =====================================================
CREATE TABLE statement_jobs (
    id              TEXT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,

    status          TEXT NOT NULL DEFAULT 'UPLOADING'
                        CHECK (status IN (
                            'UPLOADING', 'PROCESSING', 'VALIDATING', 'SAVING',
                            'COMPLETED', 'FAILED',
                            'AWAITING_CONFIRMATION', 'REJECTED'
                        )),

    -- Human-readable stage message for frontend progress display
    stage_message   TEXT,

    -- JSON result:
    --   COMPLETED          → { total_extracted, total_inserted, duplicates_skipped, validation_status, dummy_inserted }
    --   AWAITING_CONFIRMATION → { pending_transactions[], total_extracted, duplicates_skipped,
    --                             delta, allowed_delta, delta_status, dummy_type, latest_date }
    result          JSONB,

    -- Set on FAILED
    error_message   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_statement_jobs_user ON statement_jobs(user_id);

-- =====================================================
-- EVENT LOG
-- =====================================================
CREATE TABLE event_log (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    entity_type         TEXT NOT NULL,
    entity_id           BIGINT NOT NULL,

    event_type          TEXT NOT NULL,

    payload             JSONB NOT NULL,
    resulting_version   INT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================
-- STATE SNAPSHOTS (optional)
-- =====================================================
CREATE TABLE state_snapshots (
    id              BIGINT PRIMARY KEY,
    entity_type     TEXT NOT NULL,
    entity_id       BIGINT NOT NULL,
    snapshot_data   JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
