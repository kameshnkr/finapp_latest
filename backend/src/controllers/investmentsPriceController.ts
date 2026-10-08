import type { Response } from "express";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as priceRefreshService from "../services/investmentsPriceRefreshService.js";

export async function refresh(req: AuthedRequest, res: Response): Promise<void> {
  console.log(`[investments][prices][user:${req.userId}] ▶️ Refresh requested`);
  try {
    const result = await priceRefreshService.refreshPricesForUser(req.userId);
    console.log(
      `[investments][prices][user:${req.userId}] ✅ eligible=${result.eligibleCount}, ` +
        `updated=${result.updatedCount}, alreadyCurrent=${result.alreadyCurrentCount}, ` +
        `notFound=${result.notFoundIsins.length}` +
        (result.notFoundIsins.length ? ` [${result.notFoundIsins.join(", ")}]` : "")
    );
    res.json({ ok: true, ...result });
  } catch (e) {
    // Covers both expected failures (e.g. the 409 "already in progress"
    // HttpError, which the global errorHandler intentionally does NOT log)
    // and unexpected ones — rethrown unchanged so errorHandler still sets
    // the correct status code/body; this is purely for visibility.
    console.log(
      `[investments][prices][user:${req.userId}] ❌ Failed — ${e instanceof Error ? e.message : String(e)}`
    );
    throw e;
  }
}
