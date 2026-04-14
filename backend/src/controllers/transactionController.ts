import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as txService from "../services/transactionService.js";
import * as txQuery from "../services/transactionQueryService.js";
import { HttpError } from "../utils/errors.js";

const draftSchema = z.object({
  accountId: z.string().transform((s) => BigInt(s)),
  direction: z.enum(["debit", "credit"]),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/),
  note: z.string().nullable().optional(),
});

const settleSchema = z.object({
  transactionIds: z.array(z.string().transform((s) => BigInt(s))).min(1),
  transactionType: z.enum(["expense", "expense_refund", "transfer"]),
  budgetId: z
    .string()
    .transform((s) => BigInt(s))
    .optional(),
  categoryId: z
    .string()
    .transform((s) => BigInt(s))
    .optional(),
});

const updateSettledSchema = z.object({
  accountId: z.string().transform((s) => BigInt(s)),
  budgetId: z
    .string()
    .transform((s) => BigInt(s))
    .optional(),
  categoryId: z
    .string()
    .transform((s) => BigInt(s))
    .optional(),
  direction: z.enum(["debit", "credit"]),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/),
  transactionType: z.enum(["expense", "expense_refund", "transfer"]),
  note: z.string().nullable().optional(),
  version: z.number().int().positive(),
});

const listQuerySchema = z.object({
  from: z.string().min(1, "from is required"),
  to: z.string().min(1, "to is required"),
  limit: z
    .string()
    .optional()
    .transform((s) => {
      if (!s) return 50;
      const n = parseInt(s, 10);
      return isNaN(n) ? 50 : Math.min(Math.max(n, 1), 100);
    }),
  cursor: z.string().optional(),
});

function parseDateOrThrow(value: string, field: string): Date {
  const d = new Date(value);
  if (isNaN(d.getTime())) throw new HttpError(400, `Invalid ${field}: ${value}`);
  return d;
}

export async function listDrafts(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const q = listQuerySchema.parse(req.query);
  const from = parseDateOrThrow(q.from, "from");
  const to = parseDateOrThrow(q.to, "to");
  const result = await txQuery.listForUserPaged(req.userId, "draft", {
    from,
    to,
    limit: q.limit,
    cursor: q.cursor,
  });
  res.json(result);
}

export async function listSettled(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const q = listQuerySchema.parse(req.query);
  const from = parseDateOrThrow(q.from, "from");
  const to = parseDateOrThrow(q.to, "to");
  const result = await txQuery.listForUserPaged(req.userId, "settled", {
    from,
    to,
    limit: q.limit,
    cursor: q.cursor,
  });
  res.json(result);
}

export async function createDraft(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const body = draftSchema.parse(req.body);
  const row = await txService.createDraft(
    req.userId,
    body.accountId,
    body.direction,
    body.amount,
    body.note ?? null
  );
  res.status(201).json({ transaction: txQuery.serializeTx(row) });
}

export async function settle(req: AuthedRequest, res: Response): Promise<void> {
  const body = settleSchema.parse(req.body);
  let budgetId: bigint | null = body.budgetId ?? null;
  let categoryId: bigint | null = body.categoryId ?? null;

  if (body.transactionType === "transfer") {
    categoryId = null;
    if (budgetId === null) {
      throw new HttpError(400, "Budget required for transfer");
    }
  } else {
    if (budgetId === null || categoryId === null) {
      throw new HttpError(400, "Budget and category required for this type");
    }
  }

  await txService.settleDrafts(
    req.userId,
    body.transactionIds,
    body.transactionType,
    budgetId,
    categoryId
  );
  res.json({ ok: true });
}

export async function updateSettled(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const txId = BigInt(req.params.id);
  const body = updateSettledSchema.parse(req.body);
  let budgetId: bigint | null = body.budgetId ?? null;
  let categoryId: bigint | null = body.categoryId ?? null;
  if (body.transactionType === "transfer") {
    categoryId = null;
    if (budgetId === null) {
      throw new HttpError(400, "Budget required for transfer");
    }
  } else if (budgetId === null || categoryId === null) {
    throw new HttpError(400, "Budget and category required for this type");
  }

  const updated = await txService.updateSettledTransaction(req.userId, txId, {
    accountId: body.accountId,
    budgetId,
    categoryId,
    direction: body.direction,
    amount: body.amount,
    transactionType: body.transactionType,
    note: body.note ?? null,
    version: body.version,
  });
  res.json({ transaction: txQuery.serializeTx(updated) });
}
