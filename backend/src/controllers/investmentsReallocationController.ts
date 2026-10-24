import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as reallocationService from "../services/investmentsReallocationService.js";

const movementSchema = z.object({
  accountAssetId: z.string().regex(/^\d+$/),
  fromPotId: z.string().regex(/^\d+$/),
  toPotId: z.string().regex(/^\d+$/),
  units: z.string(),
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
    `[investments][reallocation][user:${req.userId}] ▶️ Execute requested — ${body.movements.length} movement(s)`
  );
  try {
    const result = await reallocationService.executeReallocation(req.userId, body.movements);
    console.log(`[investments][reallocation][user:${req.userId}] ✅ Applied ${result.movedCount} movement(s)`);
    res.json({ ok: true, movedCount: result.movedCount });
  } catch (e) {
    console.log(
      `[investments][reallocation][user:${req.userId}] ❌ Failed — ${e instanceof Error ? e.message : String(e)}`
    );
    throw e;
  }
}
