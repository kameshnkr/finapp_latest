import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as portfolioService from "../services/investmentsPortfolioService.js";
import * as potService from "../services/investmentsPotService.js";

const createSchema = z.object({
  name: z.string().min(1).max(120),
  description: z.string().max(500).optional(),
});

const updateSchema = z.object({
  name: z.string().min(1).max(120),
  description: z.string().max(500).optional(),
  version: z.number().int().positive(),
});

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const data = await portfolioService.getPotsOverview(req.userId);
  res.json(data);
}

export async function create(req: AuthedRequest, res: Response): Promise<void> {
  const body = createSchema.parse(req.body);
  const pot = await potService.createPot(req.userId, body.name, body.description ?? null);
  res.status(201).json({ pot });
}

export async function update(req: AuthedRequest, res: Response): Promise<void> {
  const potId = BigInt(req.params.id);
  const body = updateSchema.parse(req.body);
  const pot = await potService.updatePot(
    req.userId,
    potId,
    body.name,
    body.description ?? null,
    body.version
  );
  res.json({ pot });
}
