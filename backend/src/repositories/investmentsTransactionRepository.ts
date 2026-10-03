import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsTransactionRow = {
  id: bigint;
  user_id: bigint;
  account_asset_id: bigint;
  transaction_type: string;
  units: string;
  price: string;
  amount: string;
  transaction_date: string;
  source: string;
  source_reference_id: string | null;
  fingerprint: string | null;
  allocation_status: string;
  version: number;
  created_at: Date;
  updated_at: Date;
};

const TX_COLS = `id, user_id, account_asset_id, transaction_type, units::text, price::text, amount::text,
  transaction_date::text, source, source_reference_id, fingerprint, allocation_status, version, created_at, updated_at`;

export async function findExistingFingerprints(
  db: Db,
  userId: bigint,
  fingerprints: string[]
): Promise<Set<string>> {
  if (fingerprints.length === 0) return new Set();
  const r = await db.query<{ fingerprint: string }>(
    `SELECT fingerprint FROM investments_transactions
     WHERE user_id = $1 AND fingerprint = ANY($2::text[])`,
    [userId, fingerprints]
  );
  return new Set(r.rows.map((x) => x.fingerprint));
}

export type NewInvestmentsTransactionItem = {
  accountAssetId: bigint;
  transactionType: "BUY" | "SELL";
  units: string;
  price: string;
  amount: string;
  transactionDate: string;
  sourceReferenceId: string | null;
  fingerprint: string;
  /** Defaults to 'STATEMENT' (real broker trades from an upload). Pass
   * 'RECONCILIATION' for system-generated dummy trades created to reconcile
   * a Holdings-file unit mismatch — see investmentsUploadProcessingService's
   * confirmInvestmentsUpload — so the UI can clearly label them as
   * adjustments rather than actual broker trades. */
  source?: "STATEMENT" | "MANUAL" | "RECONCILIATION";
};

export async function insertTransactions(
  client: Db,
  userId: bigint,
  items: NewInvestmentsTransactionItem[]
): Promise<InvestmentsTransactionRow[]> {
  const inserted: InvestmentsTransactionRow[] = [];
  for (const item of items) {
    const id = nextId();
    const r = await client.query<InvestmentsTransactionRow>(
      `INSERT INTO investments_transactions
         (id, user_id, account_asset_id, transaction_type, units, price, amount,
          transaction_date, source, source_reference_id, fingerprint, allocation_status)
       VALUES ($1,$2,$3,$4,$5::numeric,$6::numeric,$7::numeric,$8::date,$9,$10,$11,'UNALLOCATED')
       RETURNING ${TX_COLS}`,
      [
        id,
        userId,
        item.accountAssetId,
        item.transactionType,
        item.units,
        item.price,
        item.amount,
        item.transactionDate,
        item.source ?? "STATEMENT",
        item.sourceReferenceId,
        item.fingerprint,
      ]
    );
    inserted.push(r.rows[0]!);
  }
  return inserted;
}

export async function getTransactionForUser(
  db: Db,
  userId: bigint,
  txId: bigint
): Promise<InvestmentsTransactionRow | null> {
  const r = await db.query<InvestmentsTransactionRow>(
    `SELECT ${TX_COLS} FROM investments_transactions WHERE id = $1 AND user_id = $2`,
    [txId, userId]
  );
  return r.rows[0] ?? null;
}

export async function getTransactionsForUser(
  db: Db,
  userId: bigint,
  txIds: bigint[]
): Promise<InvestmentsTransactionRow[]> {
  if (txIds.length === 0) return [];
  const r = await db.query<InvestmentsTransactionRow>(
    `SELECT ${TX_COLS} FROM investments_transactions WHERE user_id = $1 AND id = ANY($2::bigint[])`,
    [userId, txIds]
  );
  return r.rows;
}

// ── Allocation (Unlabeled → Labeled) helpers ─────────────────────────────────

/** Row-locking select used inside the allocation transaction so concurrent
 * allocate calls on the same trade(s) can't both proceed past the
 * allocation_status check. */
export async function lockTransactionsForUser(
  client: Pool | PoolClient,
  userId: bigint,
  txIds: bigint[]
): Promise<InvestmentsTransactionRow[]> {
  if (txIds.length === 0) return [];
  const r = await client.query<InvestmentsTransactionRow>(
    `SELECT ${TX_COLS} FROM investments_transactions
     WHERE user_id = $1 AND id = ANY($2::bigint[]) FOR UPDATE`,
    [userId, txIds]
  );
  return r.rows;
}

export async function markAllocated(
  client: Pool | PoolClient,
  txIds: bigint[]
): Promise<void> {
  if (txIds.length === 0) return;
  await client.query(
    `UPDATE investments_transactions
     SET allocation_status = 'ALLOCATED', version = version + 1, updated_at = now()
     WHERE id = ANY($1::bigint[])`,
    [txIds]
  );
}

// ── Unlabeled / Labeled trade list (cursor-paginated, joined with asset info) ─

export type InvestmentsTradeListRow = InvestmentsTransactionRow & {
  isin: string;
  asset_name: string;
  symbol: string | null;
  asset_class: string;
  account_id: bigint;
  account_name: string;
};

const TRADE_LIST_COLS = `t.id, t.user_id, t.account_asset_id, t.transaction_type, t.units::text, t.price::text,
  t.amount::text, t.transaction_date::text, t.source, t.source_reference_id, t.fingerprint, t.allocation_status,
  t.version, t.created_at, t.updated_at,
  a.isin, a.name AS asset_name, a.symbol, a.asset_class, aa.account_id, acc.name AS account_name`;

export type TradesPageParams = {
  userId: bigint;
  allocationStatus: "UNALLOCATED" | "ALLOCATED";
  limit: number;
  /** YYYY-MM-DD effective-date cursor of the last-loaded row. */
  cursorDate?: string;
  cursorId?: bigint;
};

export type TradesPagedResult = {
  rows: InvestmentsTradeListRow[];
  hasMore: boolean;
};

export async function listTradesPaged(
  db: Db,
  params: TradesPageParams
): Promise<TradesPagedResult> {
  const { userId, allocationStatus, limit, cursorDate, cursorId } = params;
  const hasCursor = cursorDate !== undefined && cursorId !== undefined;
  const fetchLimit = limit + 1;
  const cursorClause = hasCursor
    ? `AND (t.transaction_date, t.id) < ($3::date, $4::bigint)`
    : "";

  const r = await db.query<InvestmentsTradeListRow>(
    `SELECT ${TRADE_LIST_COLS}
     FROM investments_transactions t
     JOIN investments_account_assets aa ON aa.id = t.account_asset_id
     JOIN investments_assets a ON a.id = aa.asset_id
     JOIN investments_accounts acc ON acc.id = aa.account_id
     WHERE t.user_id = $1 AND t.allocation_status = $2
     ${cursorClause}
     ORDER BY t.transaction_date DESC, t.id DESC
     LIMIT $${hasCursor ? 5 : 3}`,
    hasCursor
      ? [userId, allocationStatus, cursorDate, cursorId, fetchLimit]
      : [userId, allocationStatus, fetchLimit]
  );

  const rows = r.rows;
  const hasMore = rows.length > limit;
  return { rows: rows.slice(0, limit), hasMore };
}
