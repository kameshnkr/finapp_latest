import { pool } from "../db/pool.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as categoryRepo from "../repositories/categoryRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import { recalcBudgetAggregates } from "./bootstrapService.js";
import { resetExpiredBudgets, computeCurrentPeriod } from "./budgetResetService.js";
import { HttpError } from "../utils/errors.js";
import type { ResetType, ResetSchedule } from "../types/domain.js";

export async function listBudgetsWithCategories(userId: bigint) {
  // Lazy reset: advance any expired scheduled budgets before reading
  await resetExpiredBudgets(userId);

  const budgets = await budgetRepo.listBudgets(pool, userId);
  if (budgets.length === 0) return [];

  const budgetIds = budgets.map((b) => b.id);

  // Batch-fetch everything needed in parallel (4 queries regardless of budget count)
  const [allCats, estimatedByBudget, fundsByBudget, allocationCountByBudget] =
    await Promise.all([
      categoryRepo.listCategoriesForBudgets(pool, budgetIds),
      categoryRepo.sumEstimatedForBudgets(pool, budgetIds),
      allocationRepo.sumAllocationsForBudgets(pool, budgetIds),
      allocationRepo.countAllocationsForBudgets(pool, budgetIds),
    ]);

  // Group categories by budget_id
  const catsByBudget = new Map<string, typeof allCats>();
  for (const cat of allCats) {
    const key = cat.budget_id.toString();
    if (!catsByBudget.has(key)) catsByBudget.set(key, []);
    catsByBudget.get(key)!.push(cat);
  }

  return budgets.map((b) => {
    const key = b.id.toString();
    const cats = catsByBudget.get(key) ?? [];
    return {
      id: key,
      name: b.name,
      resetType: b.reset_type,
      resetSchedule: b.reset_schedule ?? null,
      periodStart: b.period_start?.toISOString() ?? null,
      periodEnd: b.period_end?.toISOString() ?? null,
      // Derived at read time — source of truth
      estimated: estimatedByBudget.get(key) ?? "0",
      spent: b.spent,
      fundsAvailable: fundsByBudget.get(key) ?? "0",
      allocationCount: allocationCountByBudget.get(key) ?? 0,
      categoryOrder: b.category_order,
      version: b.version,
      createdAt: b.created_at.toISOString(),
      updatedAt: b.updated_at.toISOString(),
      categories: cats.map((c) => ({
        id: c.id.toString(),
        name: c.name,
        estimated: c.estimated,
        spent: c.spent,
        remaining: c.remaining,
        version: c.version,
        createdAt: c.created_at.toISOString(),
        updatedAt: c.updated_at.toISOString(),
      })),
    };
  });
}

export async function updateBudgetMeta(
  userId: bigint,
  budgetId: bigint,
  body: {
    name: string;
    resetType: ResetType;
    resetSchedule: ResetSchedule | null;
    version: number;
  }
) {
  let periodStart: Date | null = null;
  let periodEnd: Date | null = null;

  if (body.resetType === "scheduled" && body.resetSchedule) {
    const period = computeCurrentPeriod(body.resetSchedule, new Date());
    periodStart = period.start;
    periodEnd = period.end;
  }

  const row = await budgetRepo.updateBudgetMeta(
    pool,
    userId,
    budgetId,
    body.name,
    body.resetType,
    body.resetSchedule,
    periodStart,
    periodEnd,
    body.version
  );
  if (!row) throw new HttpError(404, "Budget not found or version conflict");
  return row;
}

export async function upsertCategory(
  userId: bigint,
  budgetId: bigint,
  body: {
    id?: bigint;
    name: string;
    estimated: string;
    version?: number;
  }
) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const b = await budgetRepo.getBudgetForUser(client, userId, budgetId);
    if (!b) throw new HttpError(404, "Budget not found");

    if (body.id) {
      const row = await categoryRepo.updateCategoryNameAndEstimated(
        client,
        budgetId,
        body.id,
        body.name,
        body.estimated,
        body.version ?? 0
      );
      if (!row) throw new HttpError(404, "Category not found or version conflict");
    } else {
      await categoryRepo.insertCategory(client, budgetId, body.name, body.estimated);
    }

    await recalcBudgetAggregates(client, budgetId);
    await client.query("COMMIT");
    return { ok: true };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

export async function deleteCategory(
  userId: bigint,
  budgetId: bigint,
  categoryId: bigint
) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const b = await budgetRepo.getBudgetForUser(client, userId, budgetId);
    if (!b) throw new HttpError(404, "Budget not found");
    const ok = await categoryRepo.deleteCategory(client, budgetId, categoryId);
    if (!ok) throw new HttpError(404, "Category not found");
    await recalcBudgetAggregates(client, budgetId);
    await client.query("COMMIT");
    return { ok: true };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

/**
 * Budget-to-budget reallocation.
 *
 * Moves `amount` of funds from fromBudget → toBudget by updating the underlying
 * account_budget_allocations proportionally across all accounts that have
 * allocations to fromBudget (largest allocation first).
 *
 * This keeps funds_available (derived from allocations) consistent without
 * needing a stored field.
 */
export async function reallocateBetweenBudgets(
  userId: bigint,
  fromBudgetId: bigint,
  toBudgetId: bigint,
  amount: string
) {
  const amt = parseFloat(amount);
  if (amt <= 0) throw new HttpError(400, "Amount must be positive");
  if (fromBudgetId === toBudgetId) throw new HttpError(400, "Budgets must differ");

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const fromB = await budgetRepo.getBudgetForUser(client, userId, fromBudgetId);
    const toB = await budgetRepo.getBudgetForUser(client, userId, toBudgetId);
    if (!fromB || !toB) throw new HttpError(404, "Budget not found");

    // Fetch all account allocations for the source budget
    const fromAllocs = await allocationRepo.listAllocationsForBudget(client, fromBudgetId);
    const totalFrom = fromAllocs.reduce((s, a) => s + parseFloat(a.amount), 0);

    if (amt > totalFrom + 0.005) {
      throw new HttpError(
        400,
        `Insufficient funds: ${totalFrom.toFixed(2)} available in source budget`
      );
    }

    // Distribute reduction across accounts (greedy: largest allocation first)
    let remaining = amt;
    const sorted = [...fromAllocs].sort(
      (a, b) => parseFloat(b.amount) - parseFloat(a.amount)
    );

    for (const alloc of sorted) {
      if (remaining < 0.005) break;
      const current = parseFloat(alloc.amount);
      if (current <= 0) continue;
      const deduct = parseFloat(Math.min(current, remaining).toFixed(2));
      await allocationRepo.upsertAllocation(
        client, alloc.account_id, fromBudgetId, (current - deduct).toFixed(2)
      );
      await allocationRepo.adjustAllocation(
        client, alloc.account_id, toBudgetId, deduct.toFixed(2)
      );
      remaining = parseFloat((remaining - deduct).toFixed(2));
    }

    await client.query("COMMIT");
    return { ok: true };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
