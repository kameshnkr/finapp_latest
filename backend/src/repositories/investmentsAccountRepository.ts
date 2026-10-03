import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsAccountRow = {
  id: bigint;
  user_id: bigint;
  name: string;
  account_identifier: string | null;
  broker_name: string | null;
  status: string;
  version: number;
  created_at: Date;
  updated_at: Date;
};

const ACCOUNT_COLS =
  "id, user_id, name, account_identifier, broker_name, status, version, created_at, updated_at";

export async function countAccountsForUser(db: Db, userId: bigint): Promise<number> {
  const r = await db.query<{ c: string }>(
    `SELECT COUNT(*)::text AS c FROM investments_accounts WHERE user_id = $1`,
    [userId]
  );
  return Number(r.rows[0]?.c ?? 0);
}

export async function listActiveAccountsForUser(
  db: Db,
  userId: bigint
): Promise<InvestmentsAccountRow[]> {
  const r = await db.query<InvestmentsAccountRow>(
    `SELECT ${ACCOUNT_COLS} FROM investments_accounts
     WHERE user_id = $1 AND status = 'ACTIVE'
     ORDER BY created_at ASC`,
    [userId]
  );
  return r.rows;
}

export async function getAccountForUser(
  db: Db,
  userId: bigint,
  accountId: bigint
): Promise<InvestmentsAccountRow | null> {
  const r = await db.query<InvestmentsAccountRow>(
    `SELECT ${ACCOUNT_COLS} FROM investments_accounts WHERE id = $1 AND user_id = $2`,
    [accountId, userId]
  );
  return r.rows[0] ?? null;
}

export async function insertAccount(
  client: Db,
  userId: bigint,
  name: string,
  brokerName: string | null
): Promise<InvestmentsAccountRow> {
  const id = nextId();
  const r = await client.query<InvestmentsAccountRow>(
    `INSERT INTO investments_accounts (id, user_id, name, broker_name)
     VALUES ($1, $2, $3, $4)
     RETURNING ${ACCOUNT_COLS}`,
    [id, userId, name, brokerName]
  );
  return r.rows[0]!;
}

/**
 * Idempotent variant used only for default-data seeding
 * (investmentsBootstrapService) — see insertPotIfNotExists's doc-comment
 * for why the count-check-then-insert-loop needs this. Default accounts
 * always start with account_identifier = NULL, and Postgres treats NULLs
 * as distinct in a unique index, so only the (user_id, name) constraint is
 * ever actually reachable here — safe to target explicitly.
 */
export async function insertAccountIfNotExists(
  client: Db,
  userId: bigint,
  name: string,
  brokerName: string | null
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO investments_accounts (id, user_id, name, broker_name)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (user_id, name) DO NOTHING`,
    [id, userId, name, brokerName]
  );
}

export async function renameAccount(
  client: Db,
  userId: bigint,
  accountId: bigint,
  newName: string,
  version: number
): Promise<InvestmentsAccountRow | null> {
  const r = await client.query<InvestmentsAccountRow>(
    `UPDATE investments_accounts
     SET name = $1, version = version + 1, updated_at = now()
     WHERE id = $2 AND user_id = $3 AND version = $4
     RETURNING ${ACCOUNT_COLS}`,
    [newName, accountId, userId, version]
  );
  return r.rows[0] ?? null;
}

/**
 * Backfills broker_name / account_identifier from a processed statement.
 * Only ever fills in currently-NULL fields — never overwrites an existing
 * value, per the "fix mapping on first upload" business rule.
 */
export async function backfillIdentityIfMissing(
  client: Db,
  accountId: bigint,
  brokerName: string | null,
  accountIdentifier: string | null
): Promise<void> {
  await client.query(
    `UPDATE investments_accounts
     SET broker_name = COALESCE(broker_name, $1),
         account_identifier = COALESCE(account_identifier, $2),
         version = version + 1,
         updated_at = now()
     WHERE id = $3`,
    [brokerName, accountIdentifier, accountId]
  );
}
