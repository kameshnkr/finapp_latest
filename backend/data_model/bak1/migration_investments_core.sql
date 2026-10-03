-- =====================================================
-- INVESTMENTS — CORE SCHEMA
-- Parallel to Banking. All tables use the "investments_" prefix.
-- Fully independent from accounts / budgets / transactions / statement_jobs.
-- =====================================================

-- =====================================================
-- INVESTMENTS ASSETS
-- Global catalogue of tradeable assets (shared across users).
-- =====================================================
CREATE TABLE investments_assets (
    id                  BIGINT PRIMARY KEY,

    asset_class         TEXT NOT NULL
                            CHECK (asset_class IN ('MUTUAL_FUND', 'STOCK', 'ETF', 'OTHER')),
    isin                TEXT NOT NULL,
    name                TEXT NOT NULL,
    symbol              TEXT,
    -- AMFI scheme code — populated only when confidently known (statement parse or
    -- verified AMFI lookup). NOT populated from a third-party API's own internal
    -- scheme_code unless verified to be the authoritative AMFI code.
    amfi_scheme_code    BIGINT,

    status              TEXT NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (isin),
    UNIQUE (amfi_scheme_code)
);

-- =====================================================
-- INVESTMENTS ASSET PRICE HISTORY
-- =====================================================
CREATE TABLE investments_asset_price_history (
    id              BIGINT PRIMARY KEY,
    asset_id        BIGINT NOT NULL REFERENCES investments_assets(id) ON DELETE CASCADE,

    price           NUMERIC(18,4) NOT NULL CHECK (price >= 0),
    price_date      DATE NOT NULL,
    source          TEXT NOT NULL,
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Keeps repeated manual refreshes on the same day idempotent (upsert target).
    UNIQUE (asset_id, price_date, source)
);

CREATE INDEX idx_investments_asset_price_history_asset
    ON investments_asset_price_history(asset_id, price_date DESC);

-- =====================================================
-- INVESTMENTS ASSET LATEST PRICES
-- =====================================================
CREATE TABLE investments_asset_latest_prices (
    id                      BIGINT PRIMARY KEY,
    asset_id                BIGINT NOT NULL REFERENCES investments_assets(id) ON DELETE CASCADE,

    price                   NUMERIC(18,4) NOT NULL CHECK (price >= 0),
    price_date              DATE NOT NULL,
    source                  TEXT NOT NULL,
    synced_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    next_price_sync_after   TIMESTAMPTZ,

    version                 INT NOT NULL DEFAULT 1,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (asset_id)
);

-- =====================================================
-- INVESTMENTS POTS
-- Goal-based allocation buckets (Retirement, Child Education, etc).
-- NOTE: "description" is added beyond the original spec list — required by the
-- Pots tab UI ("Pot name, Pot description, Current Value") and by the default
-- pot seed data, which ships with fixed descriptions per pot.
-- =====================================================
CREATE TABLE investments_pots (
    id              BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    name            TEXT NOT NULL,
    description     TEXT,

    status          TEXT NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (user_id, name)
);

CREATE INDEX idx_investments_pots_user ON investments_pots(user_id);

-- =====================================================
-- INVESTMENTS ACCOUNTS
-- Identification/grouping only — holdings live at Account+Asset level.
-- account_identifier and broker_name start NULL and are backfilled from the
-- first successfully processed statement upload for that account.
-- =====================================================
CREATE TABLE investments_accounts (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    name                TEXT NOT NULL,
    account_identifier  TEXT,
    broker_name         TEXT,

    status              TEXT NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Multiple NULL account_identifiers per user are allowed (Postgres treats
    -- NULLs as distinct in a unique index) — needed for the two default accounts
    -- that both start out unidentified.
    UNIQUE (user_id, account_identifier),
    UNIQUE (user_id, name)
);

CREATE INDEX idx_investments_accounts_user ON investments_accounts(user_id);

-- =====================================================
-- INVESTMENTS ACCOUNT ASSETS
-- Join between an Investment Account and an Asset — this is where
-- holdings actually live (units tracked via investments_positions below).
-- =====================================================
CREATE TABLE investments_account_assets (
    id              BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id      BIGINT NOT NULL REFERENCES investments_accounts(id) ON DELETE CASCADE,
    asset_id        BIGINT NOT NULL REFERENCES investments_assets(id) ON DELETE CASCADE,

    status          TEXT NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (user_id, account_id, asset_id)
);

CREATE INDEX idx_investments_account_assets_account ON investments_account_assets(account_id);
CREATE INDEX idx_investments_account_assets_asset ON investments_account_assets(asset_id);

-- =====================================================
-- INVESTMENTS TRANSACTIONS (trades)
-- Immutable once created — units/price/amount never change after the fact.
-- =====================================================
CREATE TABLE investments_transactions (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_asset_id    BIGINT NOT NULL REFERENCES investments_account_assets(id) ON DELETE CASCADE,

    transaction_type    TEXT NOT NULL CHECK (transaction_type IN ('BUY', 'SELL')),
    units               NUMERIC(20,6) NOT NULL CHECK (units > 0),
    price               NUMERIC(18,4) NOT NULL CHECK (price >= 0),
    amount              NUMERIC(18,2) NOT NULL CHECK (amount >= 0),

    transaction_date    DATE NOT NULL,

    source                  TEXT NOT NULL DEFAULT 'STATEMENT'
                                CHECK (source IN ('STATEMENT', 'MANUAL')),
    -- Broker/source trade or order ID, when available. Nullable — some brokers
    -- don't provide one. Used as a display/debug reference only; the actual
    -- dedup key is `fingerprint`.
    source_reference_id     TEXT,
    fingerprint              TEXT,

    allocation_status    TEXT NOT NULL DEFAULT 'UNALLOCATED'
                            CHECK (allocation_status IN ('UNALLOCATED', 'ALLOCATED')),

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_investments_transactions_account_asset
    ON investments_transactions(account_asset_id);

CREATE INDEX idx_investments_transactions_unlabeled_pagination
    ON investments_transactions(user_id, transaction_date DESC, id DESC)
    WHERE allocation_status = 'UNALLOCATED';

CREATE INDEX idx_investments_transactions_labeled_pagination
    ON investments_transactions(user_id, transaction_date DESC, id DESC)
    WHERE allocation_status = 'ALLOCATED';

-- Deduplication: unique fingerprint per user, statement-imported trades only.
CREATE UNIQUE INDEX idx_investments_transactions_fingerprint
    ON investments_transactions(user_id, fingerprint)
    WHERE fingerprint IS NOT NULL;

-- =====================================================
-- INVESTMENTS TRANSACTION POT ALLOCATIONS
-- Percentage-based split of a single trade across one or more Pots.
-- allocated_units is a positive magnitude derived from the trade's units at
-- allocation time; sign (add for BUY, subtract for SELL) is applied by the
-- application layer when updating derived position tables, never stored here.
-- =====================================================
CREATE TABLE investments_transaction_pot_allocations (
    id              BIGINT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    transaction_id  BIGINT NOT NULL REFERENCES investments_transactions(id) ON DELETE CASCADE,
    pot_id          BIGINT NOT NULL REFERENCES investments_pots(id) ON DELETE CASCADE,

    allocation_method   TEXT NOT NULL DEFAULT 'PERCENTAGE'
                            CHECK (allocation_method IN ('PERCENTAGE')),
    allocation_value    NUMERIC(6,3) NOT NULL CHECK (allocation_value > 0 AND allocation_value <= 100),
    allocated_units     NUMERIC(20,6) NOT NULL CHECK (allocated_units > 0),

    version         INT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (user_id, transaction_id, pot_id)
);

CREATE INDEX idx_investments_tpa_transaction ON investments_transaction_pot_allocations(transaction_id);
CREATE INDEX idx_investments_tpa_pot ON investments_transaction_pot_allocations(pot_id);

-- =====================================================
-- DERIVED READ MODELS
-- No current_value stored anywhere — always computed at runtime from units x
-- latest price. units >= 0 is a hard DB-level invariant (Pot positions must
-- never go negative).
-- =====================================================

CREATE TABLE investments_pot_positions (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pot_id              BIGINT NOT NULL REFERENCES investments_pots(id) ON DELETE CASCADE,
    account_asset_id    BIGINT NOT NULL REFERENCES investments_account_assets(id) ON DELETE CASCADE,

    units               NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (units >= 0),

    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (user_id, pot_id, account_asset_id)
);

CREATE INDEX idx_investments_pot_positions_pot ON investments_pot_positions(pot_id);
CREATE INDEX idx_investments_pot_positions_account_asset ON investments_pot_positions(account_asset_id);

CREATE TABLE investments_positions (
    id                  BIGINT PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_asset_id    BIGINT NOT NULL REFERENCES investments_account_assets(id) ON DELETE CASCADE,

    units               NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (units >= 0),

    version             INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (user_id, account_asset_id)
);

CREATE INDEX idx_investments_positions_account_asset ON investments_positions(account_asset_id);

-- =====================================================
-- INVESTMENTS UPLOAD JOBS
-- Parallel to Banking's statement_jobs — independent table, independent
-- lifecycle, independent payload shape (per-asset reconciliation mismatches
-- rather than a single balance delta).
-- =====================================================
CREATE TABLE investments_upload_jobs (
    id              TEXT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id      BIGINT NOT NULL REFERENCES investments_accounts(id) ON DELETE CASCADE,

    status          TEXT NOT NULL DEFAULT 'UPLOADING'
                        CHECK (status IN (
                            'UPLOADING', 'PARSING', 'VALIDATING', 'RECONCILING',
                            'AWAITING_CONFIRMATION', 'SAVING',
                            'COMPLETED', 'FAILED', 'REJECTED'
                        )),

    -- Human-readable stage message for frontend progress display.
    stage_message   TEXT,

    -- JSON result:
    --   AWAITING_CONFIRMATION → { mismatches: [{ account_asset_id, asset_name, existing_units,
    --                             buy_units, sell_units, expected_units, holdings_units, delta,
    --                             dummy_type, dummy_units, dummy_price }], pending_transactions: [...] }
    --   COMPLETED             → { total_extracted, total_inserted, duplicates_skipped, reconciled_count }
    result          JSONB,

    -- Set on FAILED (incl. LLM validation failure after 1 retry)
    error_message   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_investments_upload_jobs_user ON investments_upload_jobs(user_id);
