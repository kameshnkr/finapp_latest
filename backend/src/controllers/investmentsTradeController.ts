import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as tradeQuery from "../services/investmentsTradeQueryService.js";
import * as allocationService from "../services/investmentsAllocationService.js";
import { HttpError } from "../utils/errors.js";

const listQuerySchema = z.object({
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

const allocateSchema = z.object({
  transactionIds: z.array(z.string().regex(/^\d+$/)).min(1),
  allocations: z
    .array(
      z.object({
        potId: z.string().regex(/^\d+$/),
        percentage: z.number().positive().max(100),
      })
    )
    .min(1),
});

export async function listUnlabeled(req: AuthedRequest, res: Response): Promise<void> {
  const q = listQuerySchema.parse(req.query);
  const result = await tradeQuery.listTradesPaged(req.userId, "UNALLOCATED", {
    limit: q.limit,
    cursor: q.cursor,
  });
  res.json(result);
}

export async function listLabeled(req: AuthedRequest, res: Response): Promise<void> {
  const q = listQuerySchema.parse(req.query);
  const result = await tradeQuery.listTradesPaged(req.userId, "ALLOCATED", {
    limit: q.limit,
    cursor: q.cursor,
  });
  res.json(result);
}

export async function allocate(req: AuthedRequest, res: Response): Promise<void> {
  const body = allocateSchema.parse(req.body);
  let transactionIds: bigint[];
  try {
    transactionIds = body.transactionIds.map((s) => BigInt(s));
  } catch {
    throw new HttpError(400, "Invalid transaction id");
  }

  const result = await allocationService.allocateTransactions(
    req.userId,
    transactionIds,
    body.allocations
  );
  res.json({ ok: true, allocatedCount: result.allocatedCount });
}
