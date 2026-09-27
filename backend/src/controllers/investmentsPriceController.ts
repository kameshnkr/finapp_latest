import type { Response } from "express";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as priceRefreshService from "../services/investmentsPriceRefreshService.js";

export async function refresh(req: AuthedRequest, res: Response): Promise<void> {
  const result = await priceRefreshService.refreshPricesForUser(req.userId);
  res.json({ ok: true, ...result });
}
