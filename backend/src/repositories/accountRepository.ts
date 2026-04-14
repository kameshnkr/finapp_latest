import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

export type AccountRow = {
  id: bigint;
  user_id: bigint;
  name: string;
  total_balance: string;
  description: string | null;
  version: number;
  created_at: Date;
  updated_at: Date;
};

type Db = Pool | PoolClient;

export async function countAccountsForUser(
  pool: Db,
  userId: bigint
): Promise<number> {
  const r = await pool.query<{ c: string }>(
    `SELECT COUNT(*)::text AS c FROM accounts WHERE user_id = $1`,
    [userId]
  );
  return Number(r.rows[0]?.c ?? 0);
}

export async function listAccounts(
  pool: Db,
  userId: bigint
): Promise<AccountRow[]> {
  const r = await pool.query<AccountRow>(
    `SELECT id, user_id, name, total_balance::text, description, version, created_at, updated_at
     FROM accounts WHERE user_id = $1 ORDER BY created_at ASC`,
    [userId]
  );
  return r.rows;
}

export async function getAccountForUser(
  pool: Db,
  userId: bigint,
  accountId: bigint
): Promise<AccountRow | null> {
  const r = await pool.query<AccountRow>(
    `SELECT id, user_id, name, total_balance::text, description, version, created_at, updated_at
     FROM accounts WHERE id = $1 AND user_id = $2`,
    [accountId, userId]
  );
  return r.rows[0] ?? null;
}

export async function insertAccount(
  client: Pool | PoolClient,
  userId: bigint,
  name: string,
  totalBalance: string
): Promise<AccountRow> {
  const id = nextId();
  const r = await client.query<AccountRow>(
    `INSERT INTO accounts (id, user_id, name, total_balance)
     VALUES ($1, $2, $3, $4)
     RETURNING id, user_id, name, total_balance::text, description, version, created_at, updated_at`,
    [id, userId, name, totalBalance]
  );
  return r.rows[0]!;
}

export async function updateAccountBalance(
  client: Pool | PoolClient,
  userId: bigint,
  accountId: bigint,
  totalBalance: string,
  version: number,
  name?: string
): Promise<AccountRow | null> {
  const r = await client.query<AccountRow>(
    `UPDATE accounts
     SET total_balance = $1,
         name = COALESCE($5, name),
         version = version + 1,
         updated_at = now()
     WHERE id = $2 AND user_id = $3 AND version = $4
     RETURNING id, user_id, name, total_balance::text, description, version, created_at, updated_at`,
    [totalBalance, accountId, userId, version, name ?? null]
  );
  return r.rows[0] ?? null;
}

export async function adjustAccountBalance(
  client: Pool | PoolClient,
  userId: bigint,
  accountId: bigint,
  delta: string
): Promise<AccountRow | null> {
  const r = await client.query<AccountRow>(
    `UPDATE accounts SET total_balance = total_balance + $1::numeric, version = version + 1, updated_at = now()
     WHERE id = $2 AND user_id = $3
     RETURNING id, user_id, name, total_balance::text, description, version, created_at, updated_at`,
    [delta, accountId, userId]
  );
  return r.rows[0] ?? null;
}
