import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsPotRow = {
  id: bigint;
  user_id: bigint;
  name: string;
  description: string | null;
  status: string;
  version: number;
  created_at: Date;
  updated_at: Date;
};

const POT_COLS = "id, user_id, name, description, status, version, created_at, updated_at";

export async function countPotsForUser(db: Db, userId: bigint): Promise<number> {
  const r = await db.query<{ c: string }>(
    `SELECT COUNT(*)::text AS c FROM investments_pots WHERE user_id = $1`,
    [userId]
  );
  return Number(r.rows[0]?.c ?? 0);
}

export async function listActivePotsForUser(
  db: Db,
  userId: bigint
): Promise<InvestmentsPotRow[]> {
  const r = await db.query<InvestmentsPotRow>(
    `SELECT ${POT_COLS} FROM investments_pots
     WHERE user_id = $1 AND status = 'ACTIVE'
     ORDER BY created_at ASC`,
    [userId]
  );
  return r.rows;
}

export async function getPotForUser(
  db: Db,
  userId: bigint,
  potId: bigint
): Promise<InvestmentsPotRow | null> {
  const r = await db.query<InvestmentsPotRow>(
    `SELECT ${POT_COLS} FROM investments_pots WHERE id = $1 AND user_id = $2`,
    [potId, userId]
  );
  return r.rows[0] ?? null;
}

export async function getPotsForUser(
  db: Db,
  userId: bigint,
  potIds: bigint[]
): Promise<InvestmentsPotRow[]> {
  if (potIds.length === 0) return [];
  const r = await db.query<InvestmentsPotRow>(
    `SELECT ${POT_COLS} FROM investments_pots WHERE user_id = $1 AND id = ANY($2::bigint[])`,
    [userId, potIds]
  );
  return r.rows;
}

export async function insertPot(
  client: Db,
  userId: bigint,
  name: string,
  description: string | null
): Promise<InvestmentsPotRow> {
  const id = nextId();
  const r = await client.query<InvestmentsPotRow>(
    `INSERT INTO investments_pots (id, user_id, name, description)
     VALUES ($1, $2, $3, $4)
     RETURNING ${POT_COLS}`,
    [id, userId, name, description]
  );
  return r.rows[0]!;
}

/**
 * Idempotent variant used only for default-data seeding
 * (investmentsBootstrapService) — the "does this user have any Pots yet?"
 * count-check-then-insert-loop is inherently racy under concurrent requests
 * (e.g. the Home tab's 3 parallel first-load fetches for a brand-new user
 * can all pass the count===0 check before any of them commits, then all
 * try to insert the same default Pots). ON CONFLICT DO NOTHING makes that
 * race harmless — whichever request's INSERT commits first wins the row;
 * the rest silently no-op instead of throwing a unique-violation.
 */
export async function insertPotIfNotExists(
  client: Db,
  userId: bigint,
  name: string,
  description: string | null
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO investments_pots (id, user_id, name, description)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (user_id, name) DO NOTHING`,
    [id, userId, name, description]
  );
}
