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
