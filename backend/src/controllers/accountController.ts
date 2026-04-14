import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as accountService from "../services/accountService.js";
import * as accountCreateService from "../services/accountCreateService.js";

const updateSchema = z.object({
  name: z.string().min(1).optional(),
  totalBalance: z.string().regex(/^-?\d+(\.\d{1,2})?$/),
  allocations: z.array(
    z.object({
      budgetId: z.string().transform((s) => BigInt(s)),
      amount: z.string().regex(/^-?\d+(\.\d{1,2})?$/),
    })
  ),
  version: z.number().int().positive(),
});

const reallocateSchema = z.object({
  targetBudgetId: z.string().transform((s) => BigInt(s)),
  // Frontend enforces >= 0; backend trusts the math, not sign
  targetNewAmount: z.string().regex(/^-?\d+(\.\d{1,2})?$/),
  // How much to pull from the implicit unallocated pool (>= 0)
  unallocatedDeductAmount: z
    .string()
    .regex(/^\d+(\.\d{1,2})?$/)
    .optional()
    .default("0"),
  sources: z.array(
    z.object({
      budgetId: z.string().transform((s) => BigInt(s)),
      deductAmount: z.string().regex(/^\d+(\.\d{1,2})?$/),
    })
  ),
  version: z.number().int().positive(),
});

const adjustBalanceSchema = z.object({
  newBalance: z.string().regex(/^-?\d+(\.\d{1,2})?$/),
  unallocatedAmount: z
    .string()
    .regex(/^\d+(\.\d{1,2})?$/)
    .optional()
    .default("0"),
  distributions: z.array(
    z.object({
      budgetId: z.string().transform((s) => BigInt(s)),
      amount: z.string().regex(/^\d+(\.\d{1,2})?$/),
    })
  ),
  version: z.number().int().positive(),
});

const createSchema = z.object({
  name: z.string().min(1),
});

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const data = await accountService.listAccountsWithAllocations(req.userId);
  res.json({ accounts: data });
}

export async function update(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const accountId = BigInt(req.params.id);
  const body = updateSchema.parse(req.body);
  const result = await accountService.updateAccount(req.userId, accountId, {
    name: body.name,
    totalBalance: body.totalBalance,
    allocations: body.allocations.map((a) => ({
      budgetId: a.budgetId,
      amount: a.amount,
    })),
    version: body.version,
  });
  res.json({ account: result });
}

export async function reallocate(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const accountId = BigInt(req.params.id);
  const body = reallocateSchema.parse(req.body);
  await accountService.reallocateAllocation(req.userId, accountId, {
    targetBudgetId: body.targetBudgetId,
    targetNewAmount: body.targetNewAmount,
    unallocatedDeductAmount: body.unallocatedDeductAmount,
    sources: body.sources.map((s) => ({
      budgetId: s.budgetId,
      deductAmount: s.deductAmount,
    })),
    version: body.version,
  });
  res.json({ success: true });
}

export async function adjustBalance(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const accountId = BigInt(req.params.id);
  const body = adjustBalanceSchema.parse(req.body);
  await accountService.adjustAccountBalance(req.userId, accountId, {
    newBalance: body.newBalance,
    unallocatedAmount: body.unallocatedAmount,
    distributions: body.distributions.map((d) => ({
      budgetId: d.budgetId,
      amount: d.amount,
    })),
    version: body.version,
  });
  res.json({ success: true });
}

export async function create(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const body = createSchema.parse(req.body);
  const result = await accountCreateService.createAccount(req.userId, body.name);
  res.status(201).json({ account: result });
}
