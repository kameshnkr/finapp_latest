import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";
import type { ResetType, ResetSchedule } from "../types/domain.js";

type Db = Pool | PoolClient;

export type BudgetRow = {
  id: bigint;
  user_id: bigint;
  name: string;
  reset_type: ResetType;
  reset_schedule: ResetSchedule | null;
  period_start: Date | null;
  period_end: Date | null;
  /** Stored aggregate; updated whenever category spend changes. */
  spent: string;
  category_order: unknown;
  version: number;
  created_at: Date;
  updated_at: Date;
};

const BUDGET_COLS = `
  id, user_id, name,
  reset_type, reset_schedule,
  period_start, period_end,
  spent::text,
  category_order, version, created_at, updated_at`;

export async function countBudgetsForUser(db: Db, userId: bigint): Promise<number> {
  const r = await db.query<{ c: string }>(
    `SELECT COUNT(*)::text AS c FROM budgets WHERE user_id = $1`,
    [userId]
  );
  return Number(r.rows[0]?.c ?? 0);
}

export async function listBudgets(db: Db, userId: bigint): Promise<BudgetRow[]> {
  const r = await db.query<BudgetRow>(
    `SELECT ${BUDGET_COLS} FROM budgets WHERE user_id = $1 ORDER BY created_at ASC`,
    [userId]
  );
  return r.rows;
}

export async function getBudgetForUser(
  db: Db,
  userId: bigint,
  budgetId: bigint
): Promise<BudgetRow | null> {
  const r = await db.query<BudgetRow>(
    `SELECT ${BUDGET_COLS} FROM budgets WHERE id = $1 AND user_id = $2`,
    [budgetId, userId]
  );
  return r.rows[0] ?? null;
}

export async function insertBudget(
  db: Db,
  userId: bigint,
  name: string,
  resetType: ResetType,
  resetSchedule: ResetSchedule | null,
  periodStart: Date | null,
  periodEnd: Date | null
): Promise<BudgetRow> {
  const id = nextId();
  const r = await db.query<BudgetRow>(
    `INSERT INTO budgets (
       id, user_id, name,
       reset_type, reset_schedule,
       period_start, period_end,
       spent, category_order
     ) VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, 0, '[]'::jsonb)
     RETURNING ${BUDGET_COLS}`,
    [
      id, userId, name,
      resetType, resetSchedule ? JSON.stringify(resetSchedule) : null,
      periodStart, periodEnd,
    ]
  );
  return r.rows[0]!;
}

export async function updateBudgetMeta(
  db: Db,
  userId: bigint,
  budgetId: bigint,
  name: string,
  resetType: ResetType,
  resetSchedule: ResetSchedule | null,
  periodStart: Date | null,
  periodEnd: Date | null,
  version: number
): Promise<BudgetRow | null> {
  const r = await db.query<BudgetRow>(
    `UPDATE budgets
     SET name           = $1,
         reset_type     = $2,
         reset_schedule = $3::jsonb,
         period_start   = $4,
         period_end     = $5,
         version        = version + 1,
         updated_at     = now()
     WHERE id = $6 AND user_id = $7 AND version = $8
     RETURNING ${BUDGET_COLS}`,
    [
      name, resetType, resetSchedule ? JSON.stringify(resetSchedule) : null,
      periodStart, periodEnd,
      budgetId, userId, version,
    ]
  );
  return r.rows[0] ?? null;
}

/**
 * Update only the stored spent aggregate (recomputed from category sums).
 * Bumps version so clients know the budget changed.
 */
export async function updateBudgetSpent(
  db: Db,
  budgetId: bigint,
  spent: string
): Promise<void> {
  await db.query(
    `UPDATE budgets
     SET spent      = $1::numeric,
         version    = version + 1,
         updated_at = now()
     WHERE id = $2`,
    [spent, budgetId]
  );
}

export async function updateCategoryOrder(
  db: Db,
  userId: bigint,
  budgetId: bigint,
  order: bigint[]
): Promise<void> {
  await db.query(
    `UPDATE budgets
     SET category_order = $1::jsonb,
         version        = version + 1,
         updated_at     = now()
     WHERE id = $2 AND user_id = $3`,
    [JSON.stringify(order.map(String)), budgetId, userId]
  );
}

/**
 * Idempotent conditional period reset.
 *
 * Only fires when period_end still equals oldPeriodEnd – prevents duplicate
 * resets from concurrent requests. Resets spent to 0; estimated and
 * funds_available are derived at read time so need no update here.
 *
 * Returns the number of rows updated (0 or 1).
 */
export async function resetBudgetPeriod(
  db: Db,
  budgetId: bigint,
  oldPeriodEnd: Date,
  newPeriodStart: Date,
  newPeriodEnd: Date
): Promise<number> {
  const r = await db.query(
    `UPDATE budgets
     SET period_start = $1,
         period_end   = $2,
         spent        = 0,
         version      = version + 1,
         updated_at   = now()
     WHERE id = $3
       AND period_end = $4`,
    [newPeriodStart, newPeriodEnd, budgetId, oldPeriodEnd]
  );
  return r.rowCount ?? 0;
}
