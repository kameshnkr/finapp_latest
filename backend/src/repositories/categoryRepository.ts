import type { Pool, PoolClient } from "pg";

type Db = Pool | PoolClient;
import { nextId } from "../utils/id.js";

export type CategoryRow = {
  id: bigint;
  budget_id: bigint;
  name: string;
  estimated: string;
  spent: string;
  remaining: string;
  category_type: string;
  version: number;
  created_at: Date;
  updated_at: Date;
};

export async function listCategoriesForBudget(
  pool: Db,
  budgetId: bigint
): Promise<CategoryRow[]> {
  const r = await pool.query<CategoryRow>(
    `SELECT id, budget_id, name, estimated::text, spent::text, remaining::text, category_type, version, created_at, updated_at
     FROM budget_categories WHERE budget_id = $1 ORDER BY created_at ASC`,
    [budgetId]
  );
  return r.rows;
}

export async function getCategoryForBudget(
  pool: Db,
  budgetId: bigint,
  categoryId: bigint
): Promise<CategoryRow | null> {
  const r = await pool.query<CategoryRow>(
    `SELECT id, budget_id, name, estimated::text, spent::text, remaining::text, category_type, version, created_at, updated_at
     FROM budget_categories WHERE id = $1 AND budget_id = $2`,
    [categoryId, budgetId]
  );
  return r.rows[0] ?? null;
}

export async function insertCategory(
  client: Pool | PoolClient,
  budgetId: bigint,
  name: string,
  estimated: string,
  categoryType: string = "variable"
): Promise<CategoryRow> {
  const id = nextId();
  const r = await client.query<CategoryRow>(
    `INSERT INTO budget_categories (id, budget_id, name, estimated, spent, remaining, category_type)
     VALUES ($1, $2, $3, $4::numeric, 0, $4::numeric, $5)
     RETURNING id, budget_id, name, estimated::text, spent::text, remaining::text, category_type, version, created_at, updated_at`,
    [id, budgetId, name, estimated, categoryType]
  );
  return r.rows[0]!;
}

export async function updateCategoryAmounts(
  client: Pool | PoolClient,
  categoryId: bigint,
  estimated: string,
  spent: string,
  remaining: string
): Promise<void> {
  await client.query(
    `UPDATE budget_categories SET estimated = $1::numeric, spent = $2::numeric, remaining = $3::numeric,
     version = version + 1, updated_at = now() WHERE id = $4`,
    [estimated, spent, remaining, categoryId]
  );
}

export async function updateCategoryNameAndEstimated(
  client: Pool | PoolClient,
  budgetId: bigint,
  categoryId: bigint,
  name: string,
  estimated: string,
  version: number,
  categoryType: string = "variable"
): Promise<CategoryRow | null> {
  const r = await client.query<CategoryRow>(
    `UPDATE budget_categories SET name = $1, estimated = $2::numeric,
     remaining = $2::numeric - spent, category_type = $6,
     version = version + 1, updated_at = now()
     WHERE id = $3 AND budget_id = $4 AND version = $5
     RETURNING id, budget_id, name, estimated::text, spent::text, remaining::text, category_type, version, created_at, updated_at`,
    [name, estimated, categoryId, budgetId, version, categoryType]
  );
  return r.rows[0] ?? null;
}

export async function deleteCategory(
  client: Pool | PoolClient,
  budgetId: bigint,
  categoryId: bigint
): Promise<boolean> {
  const r = await client.query(
    `DELETE FROM budget_categories WHERE id = $1 AND budget_id = $2`,
    [categoryId, budgetId]
  );
  return (r.rowCount ?? 0) > 0;
}

export async function sumCategoryEstimated(
  client: Pool | PoolClient,
  budgetId: bigint
): Promise<string> {
  const r = await client.query<{ s: string | null }>(
    `SELECT COALESCE(SUM(estimated), 0)::text AS s FROM budget_categories WHERE budget_id = $1`,
    [budgetId]
  );
  return r.rows[0]?.s ?? "0";
}

export async function sumCategorySpent(
  client: Pool | PoolClient,
  budgetId: bigint
): Promise<string> {
  const r = await client.query<{ s: string | null }>(
    `SELECT COALESCE(SUM(spent), 0)::text AS s FROM budget_categories WHERE budget_id = $1`,
    [budgetId]
  );
  return r.rows[0]?.s ?? "0";
}

// ---------------------------------------------------------------------------
// Batch variants (avoid N+1 when listing multiple budgets)
// ---------------------------------------------------------------------------

/**
 * Fetch all categories for multiple budgets in one query.
 * Returns rows ordered by budget_id, created_at for consistent grouping.
 */
export async function listCategoriesForBudgets(
  db: Pool | PoolClient,
  budgetIds: bigint[]
): Promise<CategoryRow[]> {
  if (budgetIds.length === 0) return [];
  const r = await db.query<CategoryRow>(
    `SELECT id, budget_id, name,
            estimated::text, spent::text, remaining::text,
            category_type, version, created_at, updated_at
     FROM budget_categories
     WHERE budget_id = ANY($1::bigint[])
     ORDER BY budget_id, created_at ASC`,
    [budgetIds]
  );
  return r.rows;
}

/**
 * Returns a map of budgetId → SUM(estimated) for all supplied budget IDs.
 * Missing budgets (no categories) default to "0".
 */
export async function sumEstimatedForBudgets(
  db: Pool | PoolClient,
  budgetIds: bigint[]
): Promise<Map<string, string>> {
  if (budgetIds.length === 0) return new Map();
  const r = await db.query<{ budget_id: bigint; total: string }>(
    `SELECT budget_id, COALESCE(SUM(estimated), 0)::text AS total
     FROM budget_categories
     WHERE budget_id = ANY($1::bigint[])
     GROUP BY budget_id`,
    [budgetIds]
  );
  return new Map(r.rows.map((row) => [row.budget_id.toString(), row.total]));
}
