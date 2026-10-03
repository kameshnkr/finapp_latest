import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as accountService from "../services/investmentsAccountService.js";

const createSchema = z.object({
  name: z.string().min(1).max(120),
  brokerName: z.string().max(120).optional(),
});

const renameSchema = z.object({
  name: z.string().min(1).max(120),
  version: z.number().int().positive(),
});

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const accounts = await accountService.listAccounts(req.userId);
  res.json({ accounts });
}

export async function create(req: AuthedRequest, res: Response): Promise<void> {
  const body = createSchema.parse(req.body);
  const account = await accountService.createAccount(
    req.userId,
    body.name,
    body.brokerName ?? null
  );
  res.status(201).json({ account });
}

export async function rename(req: AuthedRequest, res: Response): Promise<void> {
  const accountId = BigInt(req.params.id);
  const body = renameSchema.parse(req.body);
  const account = await accountService.renameAccount(
    req.userId,
    accountId,
    body.name,
    body.version
  );
  res.json({ account });
}
