import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsPositionRow = {
  id: bigint;
  user_id: bigint;
  account_asset_id: bigint;
  units: string;
  version: number;
};

export async function getPosition(
  db: Db,
  userId: bigint,
  accountAssetId: bigint
): Promise<InvestmentsPositionRow | null> {
  const r = await db.query<InvestmentsPositionRow>(
    `SELECT id, user_id, account_asset_id, units::text, version
     FROM investments_positions WHERE user_id = $1 AND account_asset_id = $2`,
    [userId, accountAssetId]
  );
  return r.rows[0] ?? null;
}

/**
 * Adjusts the (user, account_asset) position by a signed delta (positive for
 * BUY, negative for SELL). The DB-level CHECK (units >= 0) is the hard
 * invariant backstop — this will throw if the adjustment would go negative.
 *
 * Deliberately UPDATE-first, INSERT-as-fallback, rather than a single
 * `INSERT ... ON CONFLICT DO UPDATE`. Postgres validates CHECK constraints
 * against the raw INSERT candidate row *before* it resolves whether a
 * unique-conflict exists — so with a plain upsert, any negative delta
 * (every SELL) would fail the units>=0 check immediately on the literal
 * delta value alone, even when an existing row means the true post-merge
 * total is comfortably non-negative. Confirmed via direct reproduction
 * against this schema. An UPDATE statement's constraint check, by
 * contrast, is only ever evaluated against the final merged value, which
 * is what we actually want checked.
 */
export async function adjustPosition(
  client: Db,
  userId: bigint,
  accountAssetId: bigint,
  delta: string
): Promise<InvestmentsPositionRow> {
  const updated = await client.query<InvestmentsPositionRow>(
    `UPDATE investments_positions
     SET units = units + $3::numeric, version = version + 1, updated_at = now()
     WHERE user_id = $1 AND account_asset_id = $2
     RETURNING id, user_id, account_asset_id, units::text, version`,
    [userId, accountAssetId, delta]
  );
  if (updated.rows[0]) return updated.rows[0];

  // No existing row — insert a fresh one. If `delta` itself is negative here,
  // the CHECK constraint correctly rejects it: there's nothing to sell yet.
  const id = nextId();
  try {
    const inserted = await client.query<InvestmentsPositionRow>(
      `INSERT INTO investments_positions (id, user_id, account_asset_id, units)
       VALUES ($1, $2, $3, $4::numeric)
       RETURNING id, user_id, account_asset_id, units::text, version`,
      [id, userId, accountAssetId, delta]
    );
    return inserted.rows[0]!;
  } catch (e: unknown) {
    // Race: a concurrent call inserted the row between our UPDATE miss and this INSERT.
    if ((e as { code?: string })?.code === "23505") {
      const retry = await client.query<InvestmentsPositionRow>(
        `UPDATE investments_positions
         SET units = units + $3::numeric, version = version + 1, updated_at = now()
         WHERE user_id = $1 AND account_asset_id = $2
         RETURNING id, user_id, account_asset_id, units::text, version`,
        [userId, accountAssetId, delta]
      );
      if (retry.rows[0]) return retry.rows[0];
    }
    throw e;
  }
}

export type InvestmentsPotPositionRow = {
  id: bigint;
  user_id: bigint;
  pot_id: bigint;
  account_asset_id: bigint;
  units: string;
  version: number;
};

export async function getPotPosition(
  db: Db,
  userId: bigint,
  potId: bigint,
  accountAssetId: bigint
): Promise<InvestmentsPotPositionRow | null> {
  const r = await db.query<InvestmentsPotPositionRow>(
    `SELECT id, user_id, pot_id, account_asset_id, units::text, version
     FROM investments_pot_positions
     WHERE user_id = $1 AND pot_id = $2 AND account_asset_id = $3`,
    [userId, potId, accountAssetId]
  );
  return r.rows[0] ?? null;
}

/**
 * Adjusts a (user, pot, account_asset) position by a signed delta.
 * Positive for BUY-side allocations, negative for SELL-side allocations.
 * The DB-level CHECK (units >= 0) enforces "a Pot position must never go
 * negative" as a hard invariant — callers must still pre-validate (see
 * investmentsAllocationService) to surface a clean user-facing error instead
 * of a raw constraint violation.
 *
 * UPDATE-first, INSERT-as-fallback — see the doc-comment on adjustPosition()
 * above for why a single `INSERT ... ON CONFLICT DO UPDATE` is unsafe here:
 * Postgres would validate the CHECK against the raw negative delta alone,
 * before ever resolving the conflict against the existing (sufficient)
 * balance.
 */
export async function adjustPotPosition(
  client: Db,
  userId: bigint,
  potId: bigint,
  accountAssetId: bigint,
  delta: string
): Promise<InvestmentsPotPositionRow> {
  const updated = await client.query<InvestmentsPotPositionRow>(
    `UPDATE investments_pot_positions
     SET units = units + $4::numeric, version = version + 1, updated_at = now()
     WHERE user_id = $1 AND pot_id = $2 AND account_asset_id = $3
     RETURNING id, user_id, pot_id, account_asset_id, units::text, version`,
    [userId, potId, accountAssetId, delta]
  );
  if (updated.rows[0]) return updated.rows[0];

  const id = nextId();
  try {
    const inserted = await client.query<InvestmentsPotPositionRow>(
      `INSERT INTO investments_pot_positions (id, user_id, pot_id, account_asset_id, units)
       VALUES ($1, $2, $3, $4, $5::numeric)
       RETURNING id, user_id, pot_id, account_asset_id, units::text, version`,
      [id, userId, potId, accountAssetId, delta]
    );
    return inserted.rows[0]!;
  } catch (e: unknown) {
    if ((e as { code?: string })?.code === "23505") {
      const retry = await client.query<InvestmentsPotPositionRow>(
        `UPDATE investments_pot_positions
         SET units = units + $4::numeric, version = version + 1, updated_at = now()
         WHERE user_id = $1 AND pot_id = $2 AND account_asset_id = $3
         RETURNING id, user_id, pot_id, account_asset_id, units::text, version`,
        [userId, potId, accountAssetId, delta]
      );
      if (retry.rows[0]) return retry.rows[0];
    }
    throw e;
  }
}

export type PotPositionDetailRow = {
  account_asset_id: bigint;
  pot_id: bigint;
  units: string;
};

/** All (pot, account_asset) positions for a user — used to compute Pot
 * current values and per-asset allocation breakdowns at runtime. */
export async function listPotPositionDetailsForUser(
  db: Db,
  userId: bigint
): Promise<PotPositionDetailRow[]> {
  const r = await db.query<PotPositionDetailRow>(
    `SELECT account_asset_id, pot_id, units::text
     FROM investments_pot_positions WHERE user_id = $1`,
    [userId]
  );
  return r.rows;
}

/** Sum of a specific Pot's units for a specific asset — the exact check
 * needed before allowing a SELL allocation to that Pot. */
export async function getPotPositionUnits(
  db: Db,
  userId: bigint,
  potId: bigint,
  accountAssetId: bigint
): Promise<number> {
  const row = await getPotPosition(db, userId, potId, accountAssetId);
  return row ? parseFloat(row.units) : 0;
}
