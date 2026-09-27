import type { Response } from "express";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as portfolioService from "../services/investmentsPortfolioService.js";

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const data = await portfolioService.getPotsOverview(req.userId);
  res.json(data);
}
