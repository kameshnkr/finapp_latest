import { pool } from "../db/pool.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import { computeCurrentPeriod } from "./budgetResetService.js";
import type { ResetType, ResetSchedule } from "../types/domain.js";

export async function createBudget(
  userId: bigint,
  name: string,
  resetType: ResetType,
  resetSchedule: ResetSchedule | null
) {
  let periodStart: Date | null = null;
  let periodEnd: Date | null = null;

  if (resetType === "scheduled" && resetSchedule) {
    const period = computeCurrentPeriod(resetSchedule, new Date());
    periodStart = period.start;
    periodEnd = period.end;
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const b = await budgetRepo.insertBudget(
      client,
      userId,
      name,
      resetType,
      resetSchedule,
      periodStart,
      periodEnd
    );
    const accounts = await accountRepo.listAccounts(client, userId);
    for (const a of accounts) {
      await allocationRepo.upsertAllocation(client, a.id, b.id, "0");
    }
    await client.query("COMMIT");
    return {
      id: b.id.toString(),
      name: b.name,
      resetType: b.reset_type,
      resetSchedule: b.reset_schedule ?? null,
      periodStart: b.period_start?.toISOString() ?? null,
      periodEnd: b.period_end?.toISOString() ?? null,
      version: b.version,
    };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
