import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type RefreshableAssetRow = {
  asset_id: bigint;
  isin: string;
  name: string;
  // True when this asset was already SYNCED (i.e. someone already called
  // the external API for it) earlier today, by ANY user. Deliberately
  // based on synced_at (when we last checked), NOT price_date (the NAV's
  // own as-of date) — NAV data routinely lags by a day or more over
  // weekends/holidays, so a fresh sync can legitimately return the same
  // price_date as before; that must still count as "checked today", or
  // the skip would almost never fire.
  is_current_today: boolean;
};

/**
 * Distinct Mutual Fund / ETF assets (matched by ISIN) that this user
 * actually holds via at least one active Account+Asset — the only assets
 * eligible for the tigzig MF NAV API. Stocks/OTHER are never included here;
 * the price-refresh service never even considers them.
 *
 * Also reports whether each asset was already synced today (by ANY user's
 * earlier refresh — prices are asset-level, not per-user), so the service
 * can skip calling the external API for assets that don't need it.
 */
export async function listRefreshableAssetsForUser(
  db: Db,
  userId: bigint
): Promise<RefreshableAssetRow[]> {
  const r = await db.query<RefreshableAssetRow>(
    `SELECT DISTINCT a.id AS asset_id, a.isin, a.name,
            (lp.synced_at::date = CURRENT_DATE) AS is_current_today
     FROM investments_account_assets aa
     JOIN investments_assets a ON a.id = aa.asset_id
     LEFT JOIN investments_asset_latest_prices lp ON lp.asset_id = a.id
     WHERE aa.user_id = $1
       AND aa.status = 'ACTIVE'
       AND a.asset_class IN ('MUTUAL_FUND', 'ETF')`,
    [userId]
  );
  return r.rows.map((row) => ({ ...row, is_current_today: Boolean(row.is_current_today) }));
}

/** Upserts the single "current" price row for an asset. */
export async function upsertLatestPrice(
  client: Db,
  assetId: bigint,
  price: string,
  priceDate: string,
  source: string
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO investments_asset_latest_prices (id, asset_id, price, price_date, source, synced_at)
     VALUES ($1, $2, $3::numeric, $4::date, $5, now())
     ON CONFLICT (asset_id) DO UPDATE
       SET price = EXCLUDED.price,
           price_date = EXCLUDED.price_date,
           source = EXCLUDED.source,
           synced_at = now(),
           version = investments_asset_latest_prices.version + 1,
           updated_at = now()`,
    [id, assetId, price, priceDate, source]
  );
}

/**
 * Appends a price-history row. ON CONFLICT (asset_id, price_date, source)
 * DO UPDATE keeps repeated same-day manual refreshes idempotent rather than
 * accumulating duplicate rows for the same date.
 */
export async function insertPriceHistory(
  client: Db,
  assetId: bigint,
  price: string,
  priceDate: string,
  source: string
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO investments_asset_price_history (id, asset_id, price, price_date, source, synced_at)
     VALUES ($1, $2, $3::numeric, $4::date, $5, now())
     ON CONFLICT (asset_id, price_date, source) DO UPDATE
       SET price = EXCLUDED.price,
           synced_at = now(),
           version = investments_asset_price_history.version + 1,
           updated_at = now()`,
    [id, assetId, price, priceDate, source]
  );
}
