import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type AllocationRow = {
  id: bigint;
  account_id: bigint;
  budget_id: bigint;
  amount: string;
  version: number;
  created_at: Date;
};

export async function listAllocationsForAccounts(
  pool: Db,
  accountIds: bigint[]
): Promise<AllocationRow[]> {
  if (accountIds.length === 0) return [];
  const r = await pool.query<AllocationRow>(
    `SELECT id, account_id, budget_id, amount::text, version, created_at
     FROM account_budget_allocations WHERE account_id = ANY($1::bigint[])`,
    [accountIds]
  );
  return r.rows;
}

export async function upsertAllocation(
  client: Pool | PoolClient,
  accountId: bigint,
  budgetId: bigint,
  amount: string
): Promise<void> {
  const existing = await client.query<{ id: bigint }>(
    `SELECT id FROM account_budget_allocations WHERE account_id = $1 AND budget_id = $2`,
    [accountId, budgetId]
  );
  if (existing.rows[0]) {
    await client.query(
      `UPDATE account_budget_allocations SET amount = $1::numeric, version = version + 1 WHERE id = $2`,
      [amount, existing.rows[0].id]
    );
  } else {
    const id = nextId();
    await client.query(
      `INSERT INTO account_budget_allocations (id, account_id, budget_id, amount) VALUES ($1, $2, $3, $4::numeric)`,
      [id, accountId, budgetId, amount]
    );
  }
}

/**
 * Adjust the allocated amount for an (account, budget) pair by a signed delta.
 * Uses upsert so a missing row is created with the delta as its initial amount.
 */
export async function adjustAllocation(
  client: Pool | PoolClient,
  accountId: bigint,
  budgetId: bigint,
  delta: string
): Promise<void> {
  const id = nextId();
  await client.query(
    `INSERT INTO account_budget_allocations (id, account_id, budget_id, amount)
     VALUES ($1, $2, $3, $4::numeric)
     ON CONFLICT (account_id, budget_id) DO UPDATE
       SET amount  = account_budget_allocations.amount + EXCLUDED.amount,
           version = account_budget_allocations.version + 1`,
    [id, accountId, budgetId, delta]
  );
}

export async function deleteAllocation(
  client: Pool | PoolClient,
  accountId: bigint,
  budgetId: bigint
): Promise<void> {
  await client.query(
    `DELETE FROM account_budget_allocations WHERE account_id = $1 AND budget_id = $2`,
    [accountId, budgetId]
  );
}

// ---------------------------------------------------------------------------
// Batch / budget-centric helpers
// ---------------------------------------------------------------------------

/**
 * Returns a map of budgetId → SUM(amount) for all supplied budget IDs.
 * Missing budgets (no allocations) default to "0".
 */
export async function sumAllocationsForBudgets(
  db: Db,
  budgetIds: bigint[]
): Promise<Map<string, string>> {
  if (budgetIds.length === 0) return new Map();
  const r = await db.query<{ budget_id: bigint; total: string }>(
    `SELECT budget_id, COALESCE(SUM(amount), 0)::text AS total
     FROM account_budget_allocations
     WHERE budget_id = ANY($1::bigint[])
     GROUP BY budget_id`,
    [budgetIds]
  );
  return new Map(r.rows.map((row) => [row.budget_id.toString(), row.total]));
}

/**
 * Returns a map of budgetId → count of accounts with allocations.
 * Missing budgets (no allocations) default to 0.
 */
export async function countAllocationsForBudgets(
  db: Db,
  budgetIds: bigint[]
): Promise<Map<string, number>> {
  if (budgetIds.length === 0) return new Map();
  const r = await db.query<{ budget_id: bigint; cnt: string }>(
    `SELECT budget_id, COUNT(*)::text AS cnt
     FROM account_budget_allocations
     WHERE budget_id = ANY($1::bigint[])
     GROUP BY budget_id`,
    [budgetIds]
  );
  return new Map(
    r.rows.map((row) => [row.budget_id.toString(), parseInt(row.cnt, 10)])
  );
}

/**
 * Fetch all allocation rows for a single budget (across all accounts).
 * Used by budget-to-budget reallocation to distribute funds proportionally.
 */
export async function listAllocationsForBudget(
  db: Db,
  budgetId: bigint
): Promise<AllocationRow[]> {
  const r = await db.query<AllocationRow>(
    `SELECT id, account_id, budget_id, amount::text, version, created_at
     FROM account_budget_allocations
     WHERE budget_id = $1`,
    [budgetId]
  );
  return r.rows;
}
