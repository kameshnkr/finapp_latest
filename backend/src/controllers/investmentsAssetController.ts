import type { Response } from "express";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as portfolioService from "../services/investmentsPortfolioService.js";

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const accounts = await portfolioService.getAssetsGroupedByAccount(req.userId);
  res.json({ accounts });
}
