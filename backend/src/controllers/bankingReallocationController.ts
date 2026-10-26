import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as reallocationService from "../services/bankingReallocationService.js";

const movementSchema = z.object({
  accountId: z.string().regex(/^\d+$/),
  fromBudgetId: z.string().regex(/^\d+$/),
  toBudgetId: z.string().regex(/^\d+$/),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/),
});

const executeSchema = z.object({
  movements: z.array(movementSchema).min(1),
});

export async function getData(req: AuthedRequest, res: Response): Promise<void> {
  const data = await reallocationService.getReallocationData(req.userId);
  res.json(data);
}

export async function execute(req: AuthedRequest, res: Response): Promise<void> {
  const body = executeSchema.parse(req.body);
  console.log(
    `[banking][reallocation][user:${req.userId}] ▶️ Execute requested — ${body.movements.length} movement(s)`
  );
  try {
    const result = await reallocationService.executeReallocation(req.userId, body.movements);
    console.log(`[banking][reallocation][user:${req.userId}] ✅ Applied ${result.movedCount} movement(s)`);
    res.json({ ok: true, movedCount: result.movedCount });
  } catch (e) {
    console.log(
      `[banking][reallocation][user:${req.userId}] ❌ Failed — ${e instanceof Error ? e.message : String(e)}`
    );
    throw e;
  }
}
