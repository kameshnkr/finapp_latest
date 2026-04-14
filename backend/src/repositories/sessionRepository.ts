import type { Pool, PoolClient } from "pg";
import { randomBytes } from "crypto";
import { nextId } from "../utils/id.js";

export type SessionRow = {
  id: bigint;
  user_id: bigint;
  token: string;
  created_at: Date;
};

function randomToken(): string {
  return randomBytes(32).toString("hex");
}

export async function createSession(
  client: Pool | PoolClient,
  userId: bigint
): Promise<SessionRow> {
  const id = nextId();
  const token = randomToken();
  const r = await client.query<SessionRow>(
    `INSERT INTO sessions (id, user_id, token) VALUES ($1, $2, $3)
     RETURNING id, user_id, token, created_at`,
    [id, userId, token]
  );
  return r.rows[0]!;
}

export async function findSessionByToken(
  pool: Pool,
  token: string
): Promise<SessionRow | null> {
  const r = await pool.query<SessionRow>(
    `SELECT id, user_id, token, created_at FROM sessions WHERE token = $1`,
    [token]
  );
  return r.rows[0] ?? null;
}

export async function deleteSessionByToken(
  pool: Pool,
  token: string
): Promise<void> {
  await pool.query(`DELETE FROM sessions WHERE token = $1`, [token]);
}

export async function deleteSessionsForUser(
  client: Pool | PoolClient,
  userId: bigint
): Promise<void> {
  await client.query(`DELETE FROM sessions WHERE user_id = $1`, [userId]);
}
