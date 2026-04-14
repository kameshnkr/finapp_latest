import { pool } from "../db/pool.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import type { AccountRow } from "../repositories/accountRepository.js";
import { HttpError } from "../utils/errors.js";

export async function listAccountsWithAllocations(userId: bigint) {
  const accounts = await accountRepo.listAccounts(pool, userId);
  const ids = accounts.map((a) => a.id);
  const allocs = await allocationRepo.listAllocationsForAccounts(pool, ids);
  const budgets = await budgetRepo.listBudgets(pool, userId);
  const budgetName = new Map(budgets.map((b) => [b.id.toString(), b.name]));
  return accounts.map((a) => ({
    ...serializeAccount(a),
    allocations: allocs
      .filter((x) => x.account_id === a.id)
      .map((x) => ({
        budgetId: x.budget_id.toString(),
        budgetName: budgetName.get(x.budget_id.toString()) ?? "",
        amount: x.amount,
      })),
  }));
}

function serializeAccount(a: AccountRow) {
  return {
    id: a.id.toString(),
    name: a.name,
    totalBalance: a.total_balance,
    description: a.description,
    version: a.version,
    createdAt: a.created_at.toISOString(),
    updatedAt: a.updated_at.toISOString(),
  };
}

export async function reallocateAllocation(
  userId: bigint,
  accountId: bigint,
  body: {
    targetBudgetId: bigint;
    targetNewAmount: string;
    unallocatedDeductAmount: string;
    sources: { budgetId: bigint; deductAmount: string }[];
    version: number;
  }
) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const acc = await accountRepo.getAccountForUser(client, userId, accountId);
    if (!acc) throw new HttpError(404, "Account not found");
    if (acc.version !== body.version) throw new HttpError(409, "Version conflict");

    const targetBudget = await budgetRepo.getBudgetForUser(client, userId, body.targetBudgetId);
    if (!targetBudget) throw new HttpError(404, "Target budget not found");

    const allAllocs = await allocationRepo.listAllocationsForAccounts(client, [accountId]);
    const allocMap = new Map(allAllocs.map((a) => [a.budget_id.toString(), a.amount]));

    const currentTargetAlloc = parseFloat(allocMap.get(body.targetBudgetId.toString()) ?? "0");
    const targetNewAmount = parseFloat(body.targetNewAmount);
    const delta = parseFloat((targetNewAmount - currentTargetAlloc).toFixed(2));

    // No-op: nothing to do
    if (Math.abs(delta) < 0.005) {
      await client.query("COMMIT");
      return;
    }

    const totalBalance = parseFloat(acc.total_balance);
    const totalAllocated = [...allocMap.values()].reduce((s, v) => s + parseFloat(v), 0);
    const currentUnallocated = parseFloat((totalBalance - totalAllocated).toFixed(2));

    const unallocDeduct = parseFloat(body.unallocatedDeductAmount);
    const sourcesTotal = body.sources.reduce((s, src) => s + parseFloat(src.deductAmount), 0);

    if (delta > 0.005) {
      // ── Increase: sources must cover the delta exactly ─────────────────
      const totalDeduct = parseFloat((unallocDeduct + sourcesTotal).toFixed(2));
      if (Math.abs(totalDeduct - delta) > 0.015) {
        throw new HttpError(
          400,
          `Source deductions (${totalDeduct.toFixed(2)}) must equal required increase (${delta.toFixed(2)})`
        );
      }
      if (unallocDeduct < 0) {
        throw new HttpError(400, "Unallocated deduction cannot be negative");
      }
      if (unallocDeduct > currentUnallocated + 0.015) {
        throw new HttpError(
          400,
          `Cannot deduct ${unallocDeduct.toFixed(2)} from unallocated; only ${currentUnallocated.toFixed(2)} available`
        );
      }
      for (const src of body.sources) {
        if (src.budgetId.toString() === body.targetBudgetId.toString()) {
          throw new HttpError(400, "Source cannot be the target budget");
        }
        const srcBudget = await budgetRepo.getBudgetForUser(client, userId, src.budgetId);
        if (!srcBudget) throw new HttpError(404, `Source budget not found`);
        const deduct = parseFloat(src.deductAmount);
        if (deduct < 0) {
          throw new HttpError(400, "Source deduction amount cannot be negative");
        }
        const currentSrcAlloc = parseFloat(allocMap.get(src.budgetId.toString()) ?? "0");
        if (deduct > Math.max(0, currentSrcAlloc) + 0.015) {
          throw new HttpError(
            400,
            `Cannot deduct ${deduct.toFixed(2)} from budget with allocation ${currentSrcAlloc.toFixed(2)}`
          );
        }
      }
    } else {
      // ── Decrease: distribute freed funds to destination budgets / unallocated ─
      const freed = Math.abs(delta);
      const totalAdd = parseFloat((unallocDeduct + sourcesTotal).toFixed(2));
      if (Math.abs(totalAdd - freed) > 0.015) {
        throw new HttpError(
          400,
          `Distributions (${totalAdd.toFixed(2)}) must equal freed amount (${freed.toFixed(2)})`
        );
      }
      if (unallocDeduct < 0) {
        throw new HttpError(400, "Unallocated amount cannot be negative");
      }
      for (const dst of body.sources) {
        if (dst.budgetId.toString() === body.targetBudgetId.toString()) {
          throw new HttpError(400, "Destination cannot be the target budget");
        }
        const dstBudget = await budgetRepo.getBudgetForUser(client, userId, dst.budgetId);
        if (!dstBudget) throw new HttpError(404, `Destination budget not found`);
        const addAmt = parseFloat(dst.deductAmount);
        if (addAmt < 0) {
          throw new HttpError(400, "Destination add amount cannot be negative");
        }
      }
    }

    // ── Apply target allocation change ───────────────────────────────────
    await allocationRepo.upsertAllocation(
      client,
      accountId,
      body.targetBudgetId,
      parseFloat(body.targetNewAmount).toFixed(2)
    );

    // ── Apply source deductions (increase) / destination additions (decrease) ─
    for (const src of body.sources) {
      const currentSrcAlloc = parseFloat(allocMap.get(src.budgetId.toString()) ?? "0");
      const amt = parseFloat(src.deductAmount);
      // Increase: deduct from source. Decrease: add to destination.
      const newSrcAmount = delta > 0
        ? (currentSrcAlloc - amt).toFixed(2)
        : (currentSrcAlloc + amt).toFixed(2);
      await allocationRepo.upsertAllocation(client, accountId, src.budgetId, newSrcAmount);
    }

    // ── Bump account version ─────────────────────────────────────────────
    await client.query(
      `UPDATE accounts SET version = version + 1, updated_at = now()
       WHERE id = $1 AND user_id = $2`,
      [accountId, userId]
    );

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

export async function adjustAccountBalance(
  userId: bigint,
  accountId: bigint,
  body: {
    newBalance: string;
    unallocatedAmount: string;
    distributions: { budgetId: bigint; amount: string }[];
    version: number;
  }
) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const acc = await accountRepo.getAccountForUser(client, userId, accountId);
    if (!acc) throw new HttpError(404, "Account not found");
    if (acc.version !== body.version) throw new HttpError(409, "Version conflict");

    const currentBalance = parseFloat(acc.total_balance);
    const newBalance = parseFloat(body.newBalance);
    const delta = parseFloat((newBalance - currentBalance).toFixed(2));

    if (Math.abs(delta) < 0.005) {
      await client.query("COMMIT");
      return;
    }

    const unallocAmt = parseFloat(body.unallocatedAmount);
    const distTotal = body.distributions.reduce((s, d) => s + parseFloat(d.amount), 0);
    const totalHandled = parseFloat((unallocAmt + distTotal).toFixed(2));

    if (Math.abs(totalHandled - Math.abs(delta)) > 0.015) {
      throw new HttpError(
        400,
        `Distributions (${totalHandled.toFixed(2)}) must equal balance change (${Math.abs(delta).toFixed(2)})`
      );
    }
    if (unallocAmt < 0) throw new HttpError(400, "Unallocated amount cannot be negative");

    for (const d of body.distributions) {
      const budget = await budgetRepo.getBudgetForUser(client, userId, d.budgetId);
      if (!budget) throw new HttpError(404, "Budget not found");
      if (parseFloat(d.amount) < 0) throw new HttpError(400, "Distribution amount cannot be negative");
    }

    // ── Update account total_balance ─────────────────────────────────────
    await client.query(
      `UPDATE accounts SET total_balance = $1, version = version + 1, updated_at = now()
       WHERE id = $2 AND user_id = $3`,
      [newBalance.toFixed(2), accountId, userId]
    );

    // ── Apply budget allocation changes ──────────────────────────────────
    const allAllocs = await allocationRepo.listAllocationsForAccounts(client, [accountId]);
    const allocMap = new Map(allAllocs.map((a) => [a.budget_id.toString(), a.amount]));

    for (const d of body.distributions) {
      const current = parseFloat(allocMap.get(d.budgetId.toString()) ?? "0");
      const amt = parseFloat(d.amount);
      // Increase: add to budget. Decrease: deduct from budget.
      const newAlloc = delta > 0
        ? (current + amt).toFixed(2)
        : (current - amt).toFixed(2);
      await allocationRepo.upsertAllocation(client, accountId, d.budgetId, newAlloc);
    }

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

export async function updateAccount(
  userId: bigint,
  accountId: bigint,
  body: {
    name?: string;
    totalBalance: string;
    allocations: { budgetId: bigint; amount: string }[];
    version: number;
  }
) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const acc = await accountRepo.getAccountForUser(client, userId, accountId);
    if (!acc) throw new HttpError(404, "Account not found");
    if (acc.version !== body.version) throw new HttpError(409, "Version conflict");

    const oldAllocs = await allocationRepo.listAllocationsForAccounts(client, [accountId]);
    const remainingOld = new Map(
      oldAllocs.map((o) => [o.budget_id.toString(), o.amount])
    );

    const updated = await accountRepo.updateAccountBalance(
      client,
      userId,
      accountId,
      body.totalBalance,
      body.version,
      body.name
    );
    if (!updated) throw new HttpError(409, "Update failed");

    for (const row of body.allocations) {
      const b = await budgetRepo.getBudgetForUser(client, userId, row.budgetId);
      if (!b) throw new HttpError(404, "Budget not found");
      const key = row.budgetId.toString();
      await allocationRepo.upsertAllocation(
        client,
        accountId,
        row.budgetId,
        row.amount
      );
      remainingOld.delete(key);
    }

    for (const [budgetIdStr] of remainingOld.entries()) {
      await allocationRepo.deleteAllocation(client, accountId, BigInt(budgetIdStr));
    }

    await client.query("COMMIT");
    return serializeAccount(updated);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
