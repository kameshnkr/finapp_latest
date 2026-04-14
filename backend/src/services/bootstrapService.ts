import type { PoolClient } from "pg";
import { pool } from "../db/pool.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as categoryRepo from "../repositories/categoryRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";

async function ensureDisplayOrder(
  client: PoolClient,
  userId: bigint,
  accountIds: bigint[]
): Promise<void> {
  await client.query(
    `INSERT INTO accounts_display_order (user_id, display_order)
     VALUES ($1, $2::jsonb)
     ON CONFLICT (user_id) DO UPDATE SET display_order = EXCLUDED.display_order`,
    [userId, JSON.stringify(accountIds.map(String))]
  );
}

export async function ensureDefaultDataForUser(userId: bigint): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const ac = await accountRepo.countAccountsForUser(client, userId);
    const bc = await budgetRepo.countBudgetsForUser(client, userId);
    if (ac >= 1 && bc >= 1) {
      await client.query("COMMIT");
      return;
    }

    const axis = await accountRepo.insertAccount(client, userId, "Axis Account", "0");
    const hdfc = await accountRepo.insertAccount(client, userId, "HDFC Account", "0");
    await ensureDisplayOrder(client, userId, [axis.id, hdfc.id]);

    const monthly = await budgetRepo.insertBudget(
      client, userId, "Monthly Budget", "manual", null, null, null
    );
    const travel = await budgetRepo.insertBudget(
      client, userId, "Travel Budget", "manual", null, null, null
    );
    const home = await budgetRepo.insertBudget(
      client, userId, "Home Renovation Budget", "manual", null, null, null
    );

    for (const b of [monthly, travel, home]) {
      await allocationRepo.upsertAllocation(client, axis.id, b.id, "0");
      await allocationRepo.upsertAllocation(client, hdfc.id, b.id, "0");
    }

    const monthlyCats = ["Electricity Bill", "House EMI", "Groceries", "Shopping"];
    for (const name of monthlyCats) {
      await categoryRepo.insertCategory(client, monthly.id, name, "0");
    }
    const travelCats = ["Flights", "Hotels", "Food"];
    for (const name of travelCats) {
      await categoryRepo.insertCategory(client, travel.id, name, "0");
    }
    const homeCats = ["Materials", "Labor", "Permits"];
    for (const name of homeCats) {
      await categoryRepo.insertCategory(client, home.id, name, "0");
    }

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

/**
 * Recomputes the budget's stored `spent` aggregate from its categories.
 * estimated and funds_available are no longer stored; they are derived at read time.
 */
export async function recalcBudgetAggregates(
  client: PoolClient,
  budgetId: bigint
): Promise<void> {
  const spent = await categoryRepo.sumCategorySpent(client, budgetId);
  await budgetRepo.updateBudgetSpent(client, budgetId, spent);
}
