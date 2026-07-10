import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export interface SnapshotInput {
  budgetId: bigint;
  estimated: string;
  spent: string;
  fundsAvailable: string;
  periodStart: Date | null;
  periodEnd: Date | null;
}

export interface SnapshotRow {
  id: string;
  estimated: string;
  spent: string;
  funds_available: string;
  period_start: Date | null;
  period_end: Date | null;
  created_at: Date;
}

export async function listSnapshots(
  db: Db,
  userId: bigint,
  budgetId: bigint
): Promise<SnapshotRow[]> {
  const r = await db.query<SnapshotRow>(
    `SELECT s.id,
            s.estimated::text,
            s.spent::text,
            s.funds_available::text,
            s.period_start,
            s.period_end,
            s.created_at
     FROM budget_snapshots s
     JOIN budgets b ON b.id = s.budget_id
     WHERE s.budget_id = $1
       AND b.user_id   = $2
     ORDER BY s.created_at DESC`,
    [budgetId, userId]
  );
  return r.rows;
}

export async function insertBudgetSnapshot(db: Db, input: SnapshotInput): Promise<void> {
  await db.query(
    `INSERT INTO budget_snapshots
       (id, budget_id, estimated, spent, funds_available, period_start, period_end)
     VALUES ($1, $2, $3::numeric, $4::numeric, $5::numeric, $6, $7)`,
    [
      nextId(),
      input.budgetId,
      input.estimated,
      input.spent,
      input.fundsAvailable,
      input.periodStart,
      input.periodEnd,
    ]
  );
}

/** Batch insert – use when resetting multiple budgets in one go. */
export async function insertBudgetSnapshots(db: Db, inputs: SnapshotInput[]): Promise<void> {
  if (inputs.length === 0) return;
  const placeholders: string[] = [];
  const values: unknown[] = [];
  inputs.forEach((input, i) => {
    const b = i * 7;
    placeholders.push(
      `($${b + 1}, $${b + 2}, $${b + 3}::numeric, $${b + 4}::numeric, $${b + 5}::numeric, $${b + 6}, $${b + 7})`
    );
    values.push(
      nextId(),
      input.budgetId,
      input.estimated,
      input.spent,
      input.fundsAvailable,
      input.periodStart,
      input.periodEnd
    );
  });
  await db.query(
    `INSERT INTO budget_snapshots
       (id, budget_id, estimated, spent, funds_available, period_start, period_end)
     VALUES ${placeholders.join(", ")}`,
    values
  );
}
