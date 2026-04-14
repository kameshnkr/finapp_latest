import type { PoolClient } from "pg";
import * as accountRepo from "../repositories/accountRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import type { TransactionRow } from "../repositories/transactionRepository.js";
import type { TransactionType } from "../types/domain.js";
import { recalcBudgetAggregates } from "./bootstrapService.js";
import { HttpError } from "../utils/errors.js";

function num(s: string): number {
  return parseFloat(s);
}

async function assertBudgetOwned(
  client: PoolClient,
  userId: bigint,
  budgetId: bigint
): Promise<void> {
  const r = await client.query(
    `SELECT 1 FROM budgets WHERE id = $1 AND user_id = $2`,
    [budgetId, userId]
  );
  if (r.rowCount === 0) throw new HttpError(404, "Budget not found");
}

async function assertCategoryInBudget(
  client: PoolClient,
  budgetId: bigint,
  categoryId: bigint
): Promise<void> {
  const r = await client.query(
    `SELECT 1 FROM budget_categories WHERE id = $1 AND budget_id = $2`,
    [categoryId, budgetId]
  );
  if (r.rowCount === 0) throw new HttpError(404, "Category not found");
}

export async function applySettlement(
  client: PoolClient,
  userId: bigint,
  tx: TransactionRow,
  transactionType: TransactionType,
  budgetId: bigint | null,
  categoryId: bigint | null
): Promise<void> {
  const amt = num(tx.amount);

  if (transactionType === "transfer") {
    if (!budgetId) throw new HttpError(400, "Budget required for transfer");
    if (categoryId !== null) throw new HttpError(400, "Transfer must not include a category");
    await assertBudgetOwned(client, userId, budgetId);

    const delta = tx.direction === "debit" ? -amt : amt;
    const acc = await accountRepo.adjustAccountBalance(client, userId, tx.account_id, delta.toFixed(2));
    if (!acc) throw new HttpError(404, "Account not found");

    // adjustAllocation is the source of truth for funds_available (derived at read time)
    await allocationRepo.adjustAllocation(client, tx.account_id, budgetId, delta.toFixed(2));
    await recalcBudgetAggregates(client, budgetId);
    return;
  }

  if (!budgetId) throw new HttpError(400, "Budget required for this type");
  if (transactionType === "expense" || transactionType === "expense_refund") {
    if (!categoryId) throw new HttpError(400, "Category required");
  }

  await assertBudgetOwned(client, userId, budgetId);
  await assertCategoryInBudget(client, budgetId, categoryId!);

  if (transactionType === "expense") {
    if (tx.direction !== "debit") {
      throw new HttpError(400, "Expense settlements expect a debited draft");
    }
    const acc = await accountRepo.adjustAccountBalance(client, userId, tx.account_id, (-amt).toFixed(2));
    if (!acc) throw new HttpError(404, "Account not found");

    await client.query(
      `UPDATE budget_categories
       SET spent   = spent + $1::numeric,
           version = version + 1, updated_at = now()
       WHERE id = $2`,
      [amt.toFixed(2), categoryId]
    );
    await client.query(
      `UPDATE budget_categories
       SET remaining = estimated - spent,
           version   = version + 1, updated_at = now()
       WHERE id = $1`,
      [categoryId]
    );
    await allocationRepo.adjustAllocation(client, tx.account_id, budgetId, (-amt).toFixed(2));
    await recalcBudgetAggregates(client, budgetId);
    return;
  }

  if (transactionType === "expense_refund") {
    if (tx.direction !== "credit") {
      throw new HttpError(400, "Expense refund settlements expect a credited draft");
    }
    const acc = await accountRepo.adjustAccountBalance(client, userId, tx.account_id, amt.toFixed(2));
    if (!acc) throw new HttpError(404, "Account not found");

    await client.query(
      `UPDATE budget_categories
       SET spent   = spent - $1::numeric,
           version = version + 1, updated_at = now()
       WHERE id = $2`,
      [amt.toFixed(2), categoryId]
    );
    await client.query(
      `UPDATE budget_categories
       SET remaining = estimated - spent,
           version   = version + 1, updated_at = now()
       WHERE id = $1`,
      [categoryId]
    );
    await allocationRepo.adjustAllocation(client, tx.account_id, budgetId, amt.toFixed(2));
    await recalcBudgetAggregates(client, budgetId);
  }
}

export async function revertSettlement(
  client: PoolClient,
  userId: bigint,
  tx: TransactionRow
): Promise<void> {
  if (tx.status !== "settled" || !tx.transaction_type) return;

  const amt = num(tx.amount);
  const type = tx.transaction_type;

  if (type === "transfer") {
    const delta = tx.direction === "debit" ? amt : -amt;
    await accountRepo.adjustAccountBalance(client, userId, tx.account_id, delta.toFixed(2));
    if (tx.budget_id) {
      await allocationRepo.adjustAllocation(client, tx.account_id, tx.budget_id, delta.toFixed(2));
      await recalcBudgetAggregates(client, tx.budget_id);
    }
    return;
  }

  if (!tx.budget_id || !tx.category_id) return;

  if (type === "expense") {
    await accountRepo.adjustAccountBalance(client, userId, tx.account_id, amt.toFixed(2));
    await client.query(
      `UPDATE budget_categories
       SET spent   = spent - $1::numeric,
           version = version + 1, updated_at = now()
       WHERE id = $2`,
      [amt.toFixed(2), tx.category_id]
    );
    await client.query(
      `UPDATE budget_categories
       SET remaining = estimated - spent,
           version   = version + 1, updated_at = now()
       WHERE id = $1`,
      [tx.category_id]
    );
    await allocationRepo.adjustAllocation(client, tx.account_id, tx.budget_id, amt.toFixed(2));
    await recalcBudgetAggregates(client, tx.budget_id);
    return;
  }

  if (type === "expense_refund") {
    await accountRepo.adjustAccountBalance(client, userId, tx.account_id, (-amt).toFixed(2));
    await client.query(
      `UPDATE budget_categories
       SET spent   = spent + $1::numeric,
           version = version + 1, updated_at = now()
       WHERE id = $2`,
      [amt.toFixed(2), tx.category_id]
    );
    await client.query(
      `UPDATE budget_categories
       SET remaining = estimated - spent,
           version   = version + 1, updated_at = now()
       WHERE id = $1`,
      [tx.category_id]
    );
    await allocationRepo.adjustAllocation(client, tx.account_id, tx.budget_id, (-amt).toFixed(2));
    await recalcBudgetAggregates(client, tx.budget_id);
  }
}
