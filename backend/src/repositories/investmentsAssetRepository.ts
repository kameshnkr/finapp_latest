import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsAssetRow = {
  id: bigint;
  asset_class: string;
  isin: string;
  name: string;
  symbol: string | null;
  amfi_scheme_code: bigint | null;
  status: string;
  version: number;
  created_at: Date;
  updated_at: Date;
};

const ASSET_COLS =
  "id, asset_class, isin, name, symbol, amfi_scheme_code, status, version, created_at, updated_at";

export async function findAssetByIsin(db: Db, isin: string): Promise<InvestmentsAssetRow | null> {
  const r = await db.query<InvestmentsAssetRow>(
    `SELECT ${ASSET_COLS} FROM investments_assets WHERE isin = $1`,
    [isin]
  );
  return r.rows[0] ?? null;
}

export async function getAssetById(db: Db, assetId: bigint): Promise<InvestmentsAssetRow | null> {
  const r = await db.query<InvestmentsAssetRow>(
    `SELECT ${ASSET_COLS} FROM investments_assets WHERE id = $1`,
    [assetId]
  );
  return r.rows[0] ?? null;
}

export async function insertAsset(
  client: Db,
  input: {
    isin: string;
    name: string;
    symbol: string | null;
    assetClass: string;
    amfiSchemeCode: number | null;
  }
): Promise<InvestmentsAssetRow> {
  const id = nextId();
  const r = await client.query<InvestmentsAssetRow>(
    `INSERT INTO investments_assets (id, asset_class, isin, name, symbol, amfi_scheme_code)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING ${ASSET_COLS}`,
    [id, input.assetClass, input.isin, input.name, input.symbol, input.amfiSchemeCode]
  );
  return r.rows[0]!;
}

/** Idempotent find-or-create keyed by ISIN — used by the upload pipeline. */
export async function findOrCreateAssetByIsin(
  client: Db,
  input: {
    isin: string;
    name: string;
    symbol: string | null;
    assetClass: string;
    amfiSchemeCode: number | null;
  }
): Promise<InvestmentsAssetRow> {
  const existing = await findAssetByIsin(client, input.isin);
  if (existing) return existing;
  try {
    return await insertAsset(client, input);
  } catch (e: unknown) {
    // Race: another concurrent upload inserted the same ISIN first.
    if ((e as { code?: string })?.code === "23505") {
      const row = await findAssetByIsin(client, input.isin);
      if (row) return row;
    }
    throw e;
  }
}

export type InvestmentsAccountAssetRow = {
  id: bigint;
  user_id: bigint;
  account_id: bigint;
  asset_id: bigint;
  status: string;
  version: number;
};

export async function getAccountAssetForUser(
  db: Db,
  userId: bigint,
  accountAssetId: bigint
): Promise<InvestmentsAccountAssetRow | null> {
  const r = await db.query<InvestmentsAccountAssetRow>(
    `SELECT id, user_id, account_id, asset_id, status, version
     FROM investments_account_assets WHERE id = $1 AND user_id = $2`,
    [accountAssetId, userId]
  );
  return r.rows[0] ?? null;
}

/** Idempotent find-or-create for the (account, asset) pairing. */
export async function findOrCreateAccountAsset(
  client: Db,
  userId: bigint,
  accountId: bigint,
  assetId: bigint
): Promise<InvestmentsAccountAssetRow> {
  const existing = await client.query<InvestmentsAccountAssetRow>(
    `SELECT id, user_id, account_id, asset_id, status, version
     FROM investments_account_assets
     WHERE user_id = $1 AND account_id = $2 AND asset_id = $3`,
    [userId, accountId, assetId]
  );
  if (existing.rows[0]) return existing.rows[0];

  const id = nextId();
  try {
    const r = await client.query<InvestmentsAccountAssetRow>(
      `INSERT INTO investments_account_assets (id, user_id, account_id, asset_id)
       VALUES ($1, $2, $3, $4)
       RETURNING id, user_id, account_id, asset_id, status, version`,
      [id, userId, accountId, assetId]
    );
    return r.rows[0]!;
  } catch (e: unknown) {
    if ((e as { code?: string })?.code === "23505") {
      const retry = await client.query<InvestmentsAccountAssetRow>(
        `SELECT id, user_id, account_id, asset_id, status, version
         FROM investments_account_assets
         WHERE user_id = $1 AND account_id = $2 AND asset_id = $3`,
        [userId, accountId, assetId]
      );
      if (retry.rows[0]) return retry.rows[0];
    }
    throw e;
  }
}

/**
 * Flattened, per-(account, asset) detail row used by both the Assets tab and
 * the portfolio/current-value computation. units defaults to "0" when no
 * investments_positions row exists yet; latest_price/price_date are null
 * until a manual price refresh has run for that asset.
 */
export type InvestmentsAccountAssetDetailRow = {
  account_asset_id: bigint;
  account_id: bigint;
  account_name: string;
  broker_name: string | null;
  account_identifier: string | null;
  account_created_at: Date;
  asset_id: bigint;
  isin: string;
  asset_name: string;
  symbol: string | null;
  asset_class: string;
  units: string;
  latest_price: string | null;
  price_date: string | null;
};

export async function listAccountAssetDetailsForUser(
  db: Db,
  userId: bigint
): Promise<InvestmentsAccountAssetDetailRow[]> {
  const r = await db.query<InvestmentsAccountAssetDetailRow>(
    `SELECT
       aa.id AS account_asset_id,
       aa.account_id,
       acc.name AS account_name,
       acc.broker_name,
       acc.account_identifier,
       acc.created_at AS account_created_at,
       aa.asset_id,
       a.isin,
       a.name AS asset_name,
       a.symbol,
       a.asset_class,
       COALESCE(p.units, 0)::text AS units,
       lp.price::text AS latest_price,
       lp.price_date::text AS price_date
     FROM investments_account_assets aa
     JOIN investments_accounts acc ON acc.id = aa.account_id
     JOIN investments_assets a ON a.id = aa.asset_id
     LEFT JOIN investments_positions p
       ON p.account_asset_id = aa.id AND p.user_id = aa.user_id
     LEFT JOIN investments_asset_latest_prices lp
       ON lp.asset_id = a.id
     WHERE aa.user_id = $1 AND aa.status = 'ACTIVE'
     ORDER BY acc.created_at ASC, a.name ASC`,
    [userId]
  );
  return r.rows;
}
