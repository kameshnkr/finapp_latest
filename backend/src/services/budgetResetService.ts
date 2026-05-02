import { pool } from "../db/pool.js";
import { USER_TIMEZONE_OFFSET_MS } from "../config/constants.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as snapshotRepo from "../repositories/budgetSnapshotRepository.js";
import type { BudgetRow } from "../repositories/budgetRepository.js";
import type { ResetSchedule } from "../types/domain.js";

// ---------------------------------------------------------------------------
// Timezone helpers (IST = UTC+5:30, no DST – fixed offset)
// ---------------------------------------------------------------------------

interface ISTDate {
  year: number;
  month: number; // 1–12
  day: number;   // 1–31
}

function toISTDate(utcDate: Date): ISTDate {
  const shifted = new Date(utcDate.getTime() + USER_TIMEZONE_OFFSET_MS);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
  };
}

/**
 * Returns the actual last day of the given month.
 * month is 1-indexed (1 = Jan, 12 = Dec).
 * Correctly handles Feb, leap years, 30-day months, etc.
 */
function lastDayOfMonth(year: number, month: number): number {
  // Date.UTC(year, month, 0) → day-0 of the NEXT month = last day of THIS month
  // (month here is 1-indexed, but Date.UTC expects 0-indexed – passing month
  //  as-is effectively means "next month, day 0" which is what we want)
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/**
 * Converts a local IST midnight (year-month-day 00:00:00 IST) to a UTC Date.
 * month is 1-indexed.
 *
 * IST midnight = UTC midnight − 5h30m
 * e.g. 2026-04-01 00:00 IST = 2026-03-31 18:30 UTC
 */
function istMidnightToUtc(year: number, month: number, day: number): Date {
  return new Date(Date.UTC(year, month - 1, day) - USER_TIMEZONE_OFFSET_MS);
}

// ---------------------------------------------------------------------------
// Period computation
// ---------------------------------------------------------------------------

function nextMonth(year: number, month: number): { year: number; month: number } {
  return month === 12 ? { year: year + 1, month: 1 } : { year, month: month + 1 };
}

function prevMonth(year: number, month: number): { year: number; month: number } {
  return month === 1 ? { year: year - 1, month: 12 } : { year, month: month - 1 };
}

function resetDayFor(schedule: ResetSchedule, year: number, month: number): number {
  return schedule.is_last_day_of_month
    ? lastDayOfMonth(year, month)
    : schedule.date!;
}

/**
 * Given a reset schedule and the current UTC time, computes the boundaries
 * of the period that NOW falls into.
 *
 * - Period boundary rule: start <= now < end  (end is EXCLUSIVE)
 * - Multiple missed months are handled correctly – always jumps to the
 *   current valid period without looping.
 * - All boundary timestamps are computed in IST and stored as UTC.
 */
export function computeCurrentPeriod(
  schedule: ResetSchedule,
  nowUtc: Date
): { start: Date; end: Date } {
  const ist = toISTDate(nowUtc);
  const resetDayThisMonth = resetDayFor(schedule, ist.year, ist.month);

  if (ist.day >= resetDayThisMonth) {
    // Now is on or after this month's reset day → period started this month
    const start = istMidnightToUtc(ist.year, ist.month, resetDayThisMonth);
    const nm = nextMonth(ist.year, ist.month);
    const end = istMidnightToUtc(nm.year, nm.month, resetDayFor(schedule, nm.year, nm.month));
    return { start, end };
  } else {
    // Now is before this month's reset day → period started last month
    const pm = prevMonth(ist.year, ist.month);
    const start = istMidnightToUtc(pm.year, pm.month, resetDayFor(schedule, pm.year, pm.month));
    const end = istMidnightToUtc(ist.year, ist.month, resetDayThisMonth);
    return { start, end };
  }
}

// ---------------------------------------------------------------------------
// Manual reset (user-triggered)
// ---------------------------------------------------------------------------

/**
 * Manually resets a budget period, regardless of reset_type.
 *
 * - New period_start = today (IST midnight, stored as UTC)
 * - Scheduled: new period_end = computeCurrentPeriod(schedule, today).end
 * - Manual:    period_end stays null (manual budgets are always open-ended)
 * - Snapshots the old period, zeroes spent on the budget and all categories.
 */
export async function manuallyResetBudget(
  userId: bigint,
  budgetId: bigint
): Promise<void> {
  const budget = await budgetRepo.getBudgetForUser(pool, userId, budgetId);
  if (!budget) throw Object.assign(new Error("Budget not found"), { status: 404 });

  const now = new Date();

  // New period boundaries
  const newStart = istMidnightToUtc(
    toISTDate(now).year,
    toISTDate(now).month,
    toISTDate(now).day
  );
  let newEnd: Date | null = null;
  if (budget.reset_type === "scheduled" && budget.reset_schedule) {
    newEnd = computeCurrentPeriod(budget.reset_schedule, now).end;
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    // Snapshot values from source-of-truth tables (before the reset)
    const [estRes, faRes] = await Promise.all([
      client.query<{ s: string }>(
        `SELECT COALESCE(SUM(estimated), 0)::text AS s
         FROM budget_categories WHERE budget_id = $1`,
        [budget.id]
      ),
      client.query<{ s: string }>(
        `SELECT COALESCE(SUM(amount), 0)::text AS s
         FROM account_budget_allocations WHERE budget_id = $1`,
        [budget.id]
      ),
    ]);

    // Snapshot the period being closed — period_end is TODAY (newStart),
    // not the scheduled future end, because the user is resetting it now.
    await snapshotRepo.insertBudgetSnapshot(client, {
      budgetId: budget.id,
      estimated: estRes.rows[0]?.s ?? "0",
      spent: budget.spent,
      fundsAvailable: faRes.rows[0]?.s ?? "0",
      periodStart: budget.period_start,
      periodEnd: newStart, // exclusive boundary = start of new period = end of old period
    });

    // Update budget period + zero spent
    await client.query(
      `UPDATE budgets
       SET period_start = $1,
           period_end   = $2,
           spent        = 0,
           version      = version + 1,
           updated_at   = now()
       WHERE id = $3 AND user_id = $4`,
      [newStart, newEnd, budget.id, userId]
    );

    // Zero category spend
    await client.query(
      `UPDATE budget_categories
       SET spent      = 0,
           remaining  = estimated,
           updated_at = now()
       WHERE budget_id = $1`,
      [budget.id]
    );

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

function isExpired(budget: BudgetRow, nowUtc: Date): boolean {
  if (budget.reset_type !== "scheduled") return false;
  if (!budget.period_end) return false;
  // end_timestamp is EXCLUSIVE: expired when now >= end
  return nowUtc.getTime() >= budget.period_end.getTime();
}

/**
 * Lazy reset: called at the start of every list-budgets request.
 *
 * For each expired scheduled budget:
 *   1. Computes new period (always jumps directly to current valid period).
 *   2. Runs a conditional UPDATE guarded by the old period_end value
 *      (idempotent – a concurrent request that already reset will match 0 rows).
 *   3. If update succeeded (rowCount = 1):
 *      a. Inserts a snapshot of the completed period.
 *      b. Resets all category spent/remaining for the new period.
 *
 * Each budget is processed in its own transaction. Failures on one budget
 * do not block others. All budgets are processed concurrently (Promise.all).
 */
export async function resetExpiredBudgets(userId: bigint): Promise<void> {
  const budgets = await budgetRepo.listBudgets(pool, userId);
  const now = new Date();

  const expired = budgets.filter((b) => isExpired(b, now));
  if (expired.length === 0) return;

  await Promise.all(
    expired.map(async (budget) => {
      if (!budget.reset_schedule || !budget.period_end) return;

      const newPeriod = computeCurrentPeriod(budget.reset_schedule, now);
      const client = await pool.connect();

      try {
        await client.query("BEGIN");

        // Compute snapshot values from source-of-truth tables (before the reset fires)
        const [estRes, faRes] = await Promise.all([
          client.query<{ s: string }>(
            `SELECT COALESCE(SUM(estimated), 0)::text AS s
             FROM budget_categories WHERE budget_id = $1`,
            [budget.id]
          ),
          client.query<{ s: string }>(
            `SELECT COALESCE(SUM(amount), 0)::text AS s
             FROM account_budget_allocations WHERE budget_id = $1`,
            [budget.id]
          ),
        ]);
        const snapshotEstimated = estRes.rows[0]?.s ?? "0";
        const snapshotFundsAvailable = faRes.rows[0]?.s ?? "0";

        // Step 4: Conditional update – idempotent guard on old period_end
        const rowsUpdated = await budgetRepo.resetBudgetPeriod(
          client,
          budget.id,
          budget.period_end,
          newPeriod.start,
          newPeriod.end
        );

        if (rowsUpdated === 1) {
          // Step 5: Snapshot of the completed period (uses pre-reset computed values)
          await snapshotRepo.insertBudgetSnapshot(client, {
            budgetId: budget.id,
            estimated: snapshotEstimated,
            spent: budget.spent,
            fundsAvailable: snapshotFundsAvailable,
            periodStart: budget.period_start,
            periodEnd: budget.period_end,
          });

          // Reset category-level spend for the new period
          await client.query(
            `UPDATE budget_categories
             SET spent      = 0,
                 remaining  = estimated,
                 updated_at = now()
             WHERE budget_id = $1`,
            [budget.id]
          );
        }
        // rowsUpdated === 0 → another concurrent request already reset; skip silently

        await client.query("COMMIT");
      } catch (e) {
        await client.query("ROLLBACK");
        throw e;
      } finally {
        client.release();
      }
    })
  );
}
