import { pool } from "../db/pool.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";

export async function createAccount(userId: bigint, name: string) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const acc = await accountRepo.insertAccount(client, userId, name, "0");
    const budgets = await budgetRepo.listBudgets(client, userId);
    for (const b of budgets) {
      await allocationRepo.upsertAllocation(client, acc.id, b.id, "0");
    }
    await client.query("COMMIT");
    return {
      id: acc.id.toString(),
      name: acc.name,
      totalBalance: acc.total_balance,
      version: acc.version,
    };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
