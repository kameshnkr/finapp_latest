import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

export type UserRow = {
  id: bigint;
  email: string;
  created_at: Date;
};

type Db = Pool | PoolClient;

export async function findUserByEmail(
  pool: Db,
  email: string
): Promise<UserRow | null> {
  const r = await pool.query<UserRow>(
    `SELECT id, email, created_at FROM users WHERE email = $1`,
    [email]
  );
  return r.rows[0] ?? null;
}

export async function createUser(
  client: Pool | PoolClient,
  email: string
): Promise<UserRow> {
  const id = nextId();
  const r = await client.query<UserRow>(
    `INSERT INTO users (id, email) VALUES ($1, $2)
     RETURNING id, email, created_at`,
    [id, email]
  );
  return r.rows[0]!;
}

export async function findUserById(
  pool: Db,
  id: bigint
): Promise<UserRow | null> {
  const r = await pool.query<UserRow>(
    `SELECT id, email, created_at FROM users WHERE id = $1`,
    [id]
  );
  return r.rows[0] ?? null;
}
