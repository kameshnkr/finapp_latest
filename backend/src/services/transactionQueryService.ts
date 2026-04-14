import { pool } from "../db/pool.js";
import * as txRepo from "../repositories/transactionRepository.js";
import type { TxStatus } from "../types/domain.js";
import { HttpError } from "../utils/errors.js";

export type TxPageResult = {
  transactions: ReturnType<typeof serializeTx>[];
  nextCursor: string | null;
  hasMore: boolean;
};

/**
 * Returns transaction_date as a YYYY-MM-DD string.
 * pg DATE columns are parsed as raw strings (see pool.ts type parser override),
 * so no timezone conversion is needed.
 */
function effectiveDateStr(row: txRepo.TransactionRow): string {
  return row.transaction_date
    ?? row.created_at.toISOString().slice(0, 10); // fallback: should never happen
}

export async function listForUserPaged(
  userId: bigint,
  status: TxStatus,
  params: { from: Date; to: Date; limit: number; cursor?: string }
): Promise<TxPageResult> {
  let cursorDate: string | undefined;
  let cursorId: bigint | undefined;

  if (params.cursor) {
    try {
      const decoded = JSON.parse(
        Buffer.from(params.cursor, "base64url").toString("utf8")
      ) as { d: string; id: string };
      // Basic YYYY-MM-DD validation
      if (!/^\d{4}-\d{2}-\d{2}$/.test(decoded.d)) throw new Error("bad date");
      cursorDate = decoded.d;
      cursorId = BigInt(decoded.id);
    } catch {
      throw new HttpError(400, "Invalid cursor");
    }
  }

  const result = await txRepo.listTransactionsPaged(pool, {
    userId,
    status,
    from: params.from,
    to: params.to,
    limit: params.limit,
    cursorDate,
    cursorId,
  });

  let nextCursor: string | null = null;
  if (result.hasMore && result.rows.length > 0) {
    // Last row in DESC result = oldest — use its effective date as next cursor
    const oldest = result.rows[result.rows.length - 1]!;
    nextCursor = Buffer.from(
      JSON.stringify({ d: effectiveDateStr(oldest), id: oldest.id.toString() })
    ).toString("base64url");
  }

  // Drafts are returned DESC from DB; reverse to ASC so Flutter's
  // reverse:true ListView shows oldest at the bottom correctly.
  const rows =
    status === "draft" ? [...result.rows].reverse() : result.rows;

  return {
    transactions: rows.map(serializeTx),
    nextCursor,
    hasMore: result.hasMore,
  };
}

export async function listForUser(userId: bigint, status: TxStatus) {
  const rows = await txRepo.listTransactions(pool, userId, status);
  return rows.map(serializeTx);
}

export function serializeTx(
  row: import("../repositories/transactionRepository.js").TransactionRow
) {
  return {
    id: row.id.toString(),
    accountId: row.account_id.toString(),
    budgetId: row.budget_id?.toString() ?? null,
    categoryId: row.category_id?.toString() ?? null,
    direction: row.direction,
    amount: row.amount,
    status: row.status,
    source: row.source,
    transactionType: row.transaction_type,
    description: row.description,
    descriptionReadable: row.description_readable ?? null,
    note: row.note,
    settledAt: row.settled_at?.toISOString() ?? null,
    // YYYY-MM-DD string directly from pg (type parser override in pool.ts)
    transactionDate: row.transaction_date ?? null,
    version: row.version,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}
