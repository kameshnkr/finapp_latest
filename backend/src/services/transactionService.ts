import { pool } from "../db/pool.js";
import * as txRepo from "../repositories/transactionRepository.js";
import type { TransactionRow } from "../repositories/transactionRepository.js";
import * as accountRepo from "../repositories/accountRepository.js";
import type { Direction, TransactionType } from "../types/domain.js";
import { applySettlement, revertSettlement } from "./settlementService.js";
import { HttpError } from "../utils/errors.js";

export async function createDraft(
  userId: bigint,
  accountId: bigint,
  direction: Direction,
  amount: string,
  note: string | null
): Promise<TransactionRow> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const r = await client.query(
      `SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2`,
      [accountId, userId]
    );
    if (r.rowCount === 0) throw new HttpError(404, "Account not found");
    const row = await txRepo.insertDraft(
      client,
      userId,
      accountId,
      direction,
      amount,
      note
    );
    await client.query("COMMIT");
    return row;
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

export async function settleDrafts(
  userId: bigint,
  transactionIds: bigint[],
  transactionType: TransactionType,
  budgetId: bigint | null,
  categoryId: bigint | null
): Promise<void> {
  if (transactionIds.length === 0) throw new HttpError(400, "No transactions");

  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const rows = await txRepo.lockTransactionsForUser(
      client,
      userId,
      transactionIds
    );
    if (rows.length !== transactionIds.length) {
      throw new HttpError(404, "One or more transactions not found");
    }
    for (const t of rows) {
      if (t.status !== "draft") {
        throw new HttpError(400, "Transaction is not a draft");
      }
    }

    for (const t of rows) {
      await applySettlement(client, userId, t, transactionType, budgetId, categoryId);
    }

    await txRepo.settleTransactions(
      client,
      transactionIds,
      budgetId,
      categoryId,
      transactionType
    );
    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

export async function updateSettledTransaction(
  userId: bigint,
  transactionId: bigint,
  body: {
    accountId: bigint;
    budgetId: bigint | null;
    categoryId: bigint | null;
    direction: Direction;
    amount: string;
    transactionType: TransactionType;
    note: string | null;
    version: number;
  }
): Promise<TransactionRow> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const current = await txRepo.getTransactionForUser(
      client,
      userId,
      transactionId
    );
    if (!current || current.status !== "settled") {
      throw new HttpError(404, "Settled transaction not found");
    }
    if (current.version !== body.version) {
      throw new HttpError(409, "Version conflict");
    }

    const acc = await accountRepo.getAccountForUser(
      client,
      userId,
      body.accountId
    );
    if (!acc) throw new HttpError(404, "Account not found");

    await revertSettlement(client, userId, current);

    const updated = await txRepo.updateSettledTransaction(client, userId, transactionId, {
      accountId: body.accountId,
      budgetId: body.budgetId,
      categoryId: body.categoryId,
      direction: body.direction,
      amount: body.amount,
      transactionType: body.transactionType,
      note: body.note,
      version: body.version,
    });
    if (!updated) throw new HttpError(409, "Update failed");

    await applySettlement(
      client,
      userId,
      updated,
      body.transactionType,
      body.budgetId,
      body.categoryId
    );

    await client.query("COMMIT");
    return updated;
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
