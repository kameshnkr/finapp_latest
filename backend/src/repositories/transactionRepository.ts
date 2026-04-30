import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";
import type { Direction, TransactionType, TxStatus } from "../types/domain.js";

export type TransactionRow = {
  id: bigint;
  user_id: bigint;
  account_id: bigint;
  budget_id: bigint | null;
  category_id: bigint | null;
  direction: Direction;
  amount: string;
  status: TxStatus;
  source: string;
  transaction_type: TransactionType | null;
  description: string | null;
  description_readable: string | null;
  note: string | null;
  settled_at: Date | null;
  transaction_date: string | null; // YYYY-MM-DD string (pg DATE parsed as string, not Date)
  fingerprint: string | null;
  statement_seq: number | null;
  version: number;
  created_at: Date;
  updated_at: Date;
};

export async function insertDraft(
  client: Pool | PoolClient,
  userId: bigint,
  accountId: bigint,
  direction: Direction,
  amount: string,
  note: string | null
): Promise<TransactionRow> {
  const id = nextId();
  const r = await client.query<TransactionRow>(
    `INSERT INTO transactions (
       id, user_id, account_id, direction, amount, status, source, note, transaction_date
     ) VALUES ($1, $2, $3, $4, $5::numeric, 'draft', 'manual', $6, CURRENT_DATE)
     RETURNING id, user_id, account_id, budget_id, category_id, direction, amount::text, status, source,
       transaction_type, description, description_readable, note, settled_at, transaction_date, fingerprint, statement_seq, version, created_at, updated_at`,
    [id, userId, accountId, direction, amount, note]
  );
  return r.rows[0]!;
}

type Db = Pool | PoolClient;

export type PagedResult = {
  rows: TransactionRow[];
  hasMore: boolean;
};

export type PageParams = {
  userId: bigint;
  status: TxStatus;
  from: Date;
  to: Date;
  limit: number;
  /**
   * YYYY-MM-DD effective-date cursor:
   *   COALESCE(transaction_date, created_at::date) of the oldest loaded row.
   */
  cursorDate?: string;
  /** ID tie-breaker cursor */
  cursorId?: bigint;
};

const SELECT_COLS = `id, user_id, account_id, budget_id, category_id, direction, amount::text, status, source,
  transaction_type, description, description_readable, note, settled_at, transaction_date, fingerprint, statement_seq, version, created_at, updated_at`;

export async function listTransactionsPaged(
  pool: Db,
  params: PageParams
): Promise<PagedResult> {
  const { userId, status, from, to, limit, cursorDate, cursorId } = params;
  const hasCursor = cursorDate !== undefined && cursorId !== undefined;
  const fetchLimit = limit + 1;
  // from/to arrive as full ISO timestamptz strings from the frontend;
  // cast to ::date to match the DATE-typed transaction_date column.
  const cursorClause = hasCursor
    ? `AND (transaction_date, id) < ($4::date, $5::bigint)`
    : "";
  const statusLiteral = status === "draft" ? "'draft'" : "'settled'";

  const r = await pool.query<TransactionRow>(
    `SELECT ${SELECT_COLS}
     FROM transactions
     WHERE user_id = $1
       AND status = ${statusLiteral}
       AND transaction_date >= $2::timestamptz::date
       AND transaction_date <= $3::timestamptz::date
       ${cursorClause}
     ORDER BY transaction_date DESC, statement_seq DESC NULLS LAST, id DESC
     LIMIT $${hasCursor ? 6 : 4}`,
    hasCursor
      ? [userId, from, to, cursorDate, cursorId, fetchLimit]
      : [userId, from, to, fetchLimit]
  );

  const rows = r.rows;
  const hasMore = rows.length > limit;
  return { rows: rows.slice(0, limit), hasMore };
}

export async function listTransactions(
  pool: Db,
  userId: bigint,
  status: TxStatus
): Promise<TransactionRow[]> {
  const order =
    status === "draft"
      ? `ORDER BY created_at ASC`
      : `ORDER BY settled_at DESC NULLS LAST, updated_at DESC`;
  const r = await pool.query<TransactionRow>(
    `SELECT ${SELECT_COLS}
     FROM transactions WHERE user_id = $1 AND status = $2 ${order}`,
    [userId, status]
  );
  return r.rows;
}

export async function getTransactionForUser(
  pool: Pool | PoolClient,
  userId: bigint,
  txId: bigint
): Promise<TransactionRow | null> {
  const r = await pool.query<TransactionRow>(
    `SELECT id, user_id, account_id, budget_id, category_id, direction, amount::text, status, source,
            transaction_type, description, description_readable, note, settled_at, transaction_date, fingerprint, statement_seq, version, created_at, updated_at
     FROM transactions WHERE id = $1 AND user_id = $2`,
    [txId, userId]
  );
  return r.rows[0] ?? null;
}

export async function lockTransactionsForUser(
  client: Pool | PoolClient,
  userId: bigint,
  ids: bigint[]
): Promise<TransactionRow[]> {
  if (ids.length === 0) return [];
  const r = await client.query<TransactionRow>(
    `SELECT id, user_id, account_id, budget_id, category_id, direction, amount::text, status, source,
            transaction_type, description, description_readable, note, settled_at, transaction_date, fingerprint, statement_seq, version, created_at, updated_at
     FROM transactions WHERE user_id = $1 AND id = ANY($2::bigint[]) FOR UPDATE`,
    [userId, ids]
  );
  return r.rows;
}

export async function settleTransactions(
  client: Pool | PoolClient,
  ids: bigint[],
  budgetId: bigint | null,
  categoryId: bigint | null,
  transactionType: TransactionType
): Promise<void> {
  if (ids.length === 0) return;
  await client.query(
    `UPDATE transactions SET
       status = 'settled',
       budget_id = $2,
       category_id = $3,
       transaction_type = $4,
       settled_at = now(),
       updated_at = now(),
       version = version + 1
     WHERE id = ANY($1::bigint[])`,
    [ids, budgetId, categoryId, transactionType]
  );
}

export async function updateSettledTransaction(
  client: Pool | PoolClient,
  userId: bigint,
  txId: bigint,
  patch: {
    accountId: bigint;
    budgetId: bigint | null;
    categoryId: bigint | null;
    direction: Direction;
    amount: string;
    transactionType: TransactionType;
    note: string | null;
    version: number;
  }
): Promise<TransactionRow | null> {
  const r = await client.query<TransactionRow>(
    `UPDATE transactions SET
       account_id = $1,
       budget_id = $2,
       category_id = $3,
       direction = $4,
       amount = $5::numeric,
       transaction_type = $6,
       note = $7,
       updated_at = now(),
       version = version + 1
     WHERE id = $8 AND user_id = $9 AND status = 'settled' AND version = $10
     RETURNING id, user_id, account_id, budget_id, category_id, direction, amount::text, status, source,
       transaction_type, description, description_readable, note, settled_at, transaction_date, fingerprint, statement_seq, version, created_at, updated_at`,
    [
      patch.accountId,
      patch.budgetId,
      patch.categoryId,
      patch.direction,
      patch.amount,
      patch.transactionType,
      patch.note,
      txId,
      userId,
      patch.version,
    ]
  );
  return r.rows[0] ?? null;
}

// ── Balance adjustment helpers ───────────────────────────────────────────────

/**
 * Inserts a settled balance-adjustment transaction directly (no draft stage).
 * One record is created per distribution destination (budget or unallocated).
 * direction: 'credit' for balance increases, 'debit' for decreases.
 * budgetId:  null means the adjustment portion flows to/from unallocated.
 */
export async function insertBalanceAdjustmentTx(
  client: Pool | PoolClient,
  userId: bigint,
  accountId: bigint,
  direction: Direction,
  amount: string,
  budgetId: bigint | null
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO transactions (
       id, user_id, account_id, budget_id, direction, amount, status, source,
       transaction_type, settled_at, transaction_date
     ) VALUES ($1, $2, $3, $4, $5, $6::numeric, 'settled', 'manual',
       'balance_adjustment', now(), CURRENT_DATE)`,
    [id, userId, accountId, budgetId, direction, amount]
  );
}

// ── Statement upload helpers ─────────────────────────────────────────────────

export type StatementDraftItem = {
  direction: Direction;
  amount: string;
  description: string;
  descriptionReadable: string | null;
  transactionDate: string; // YYYY-MM-DD
  statementSeq: number;    // position in statement (0-based), used for ordering
  fingerprint: string;
};

/**
 * Batch-check which fingerprints already exist for a given user.
 * Returns the set of fingerprints that are already in the DB.
 */
export async function findExistingFingerprints(
  db: Pool | PoolClient,
  fingerprints: string[],
  userId: bigint
): Promise<Set<string>> {
  if (fingerprints.length === 0) return new Set();
  const r = await db.query<{ fingerprint: string }>(
    `SELECT fingerprint FROM transactions
     WHERE user_id = $1 AND fingerprint = ANY($2::text[])`,
    [userId, fingerprints]
  );
  return new Set(r.rows.map((row) => row.fingerprint));
}

export type StatementDraftNet = {
  netCredits: number;
  netDebits: number;
  /** netCredits - netDebits */
  net: number;
};

/**
 * Returns the net of all existing statement-sourced draft transactions for an account.
 * Only source='statement' rows are included to avoid double-counting manual drafts
 * that might correspond to transactions also present in a new upload.
 */
export async function getNetStatementDrafts(
  db: Pool | PoolClient,
  userId: bigint,
  accountId: bigint
): Promise<StatementDraftNet> {
  const r = await db.query<{ net_credits: string; net_debits: string }>(
    `SELECT
       COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END), 0)::text AS net_credits,
       COALESCE(SUM(CASE WHEN direction = 'debit'  THEN amount ELSE 0 END), 0)::text AS net_debits
     FROM transactions
     WHERE user_id = $1
       AND account_id = $2
       AND status = 'draft'
       AND source = 'statement'`,
    [userId, accountId]
  );
  const netCredits = parseFloat(r.rows[0]?.net_credits ?? "0");
  const netDebits  = parseFloat(r.rows[0]?.net_debits  ?? "0");
  return { netCredits, netDebits, net: netCredits - netDebits };
}

/**
 * Bulk-insert statement draft transactions.
 * Uses ON CONFLICT DO NOTHING on the partial fingerprint index as a safety net
 * against race conditions (pre-check via findExistingFingerprints is the primary guard).
 * Returns the number of rows actually inserted.
 */
export async function insertStatementDrafts(
  db: Pool | PoolClient,
  userId: bigint,
  accountId: bigint,
  items: StatementDraftItem[]
): Promise<number> {
  if (items.length === 0) return 0;

  const values: unknown[] = [];
  const rows: string[] = [];
  let p = 1;

  for (const item of items) {
    const id = nextId();
    rows.push(
      `($${p}, $${p + 1}, $${p + 2}, $${p + 3}, $${p + 4}::numeric, 'draft', 'statement', $${p + 5}, $${p + 6}, $${p + 7}::date, $${p + 8}, $${p + 9}::int)`
    );
    values.push(
      id,
      userId,
      accountId,
      item.direction,
      item.amount,
      item.description,
      item.descriptionReadable,
      item.transactionDate,
      item.fingerprint,
      item.statementSeq
    );
    p += 10;
  }

  const result = await db.query(
    `INSERT INTO transactions
       (id, user_id, account_id, direction, amount, status, source, description, description_readable, transaction_date, fingerprint, statement_seq)
     VALUES ${rows.join(", ")}
     ON CONFLICT (fingerprint) WHERE fingerprint IS NOT NULL DO NOTHING`,
    values
  );
  return result.rowCount ?? 0;
}
