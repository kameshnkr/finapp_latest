import type { Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as budgetService from "../services/budgetService.js";
import * as budgetCreateService from "../services/budgetCreateService.js";

// ---------------------------------------------------------------------------
// Shared sub-schemas
// ---------------------------------------------------------------------------

const resetScheduleSchema = z
  .object({
    type: z.literal("every_month_on_date"),
    /** Day of month (1–28). Must be null when is_last_day_of_month is true. */
    date: z.number().int().min(1).max(28).nullable(),
    is_last_day_of_month: z.boolean(),
  })
  .refine(
    (s) => s.is_last_day_of_month || s.date !== null,
    { message: "date is required when is_last_day_of_month is false" }
  );

// ---------------------------------------------------------------------------
// Route-level schemas
// ---------------------------------------------------------------------------

const updateMetaSchema = z
  .object({
    name: z.string().min(1),
    reset_type: z.enum(["scheduled", "manual"]),
    reset_schedule: resetScheduleSchema.nullable().optional(),
    version: z.number().int().positive(),
  })
  .refine(
    (b) => b.reset_type !== "scheduled" || !!b.reset_schedule,
    { message: "reset_schedule is required when reset_type is 'scheduled'" }
  );

const categoryUpsertSchema = z.object({
  id: z.string().optional().transform((s) => (s ? BigInt(s) : undefined)),
  name: z.string().min(1),
  estimated: z.string().regex(/^\d+(\.\d{1,2})?$/),
  version: z.number().int().positive().optional(),
});

const createBudgetSchema = z
  .object({
    name: z.string().min(1),
    reset_type: z.enum(["scheduled", "manual"]).default("manual"),
    reset_schedule: resetScheduleSchema.nullable().optional(),
  })
  .refine(
    (b) => b.reset_type !== "scheduled" || !!b.reset_schedule,
    { message: "reset_schedule is required when reset_type is 'scheduled'" }
  );

const reallocateSchema = z.object({
  fromBudgetId: z.string().transform((s) => BigInt(s)),
  toBudgetId: z.string().transform((s) => BigInt(s)),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/),
});

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

export async function list(req: AuthedRequest, res: Response): Promise<void> {
  const data = await budgetService.listBudgetsWithCategories(req.userId);
  res.json({ budgets: data });
}

export async function updateMeta(req: AuthedRequest, res: Response): Promise<void> {
  const budgetId = BigInt(req.params.id);
  const body = updateMetaSchema.parse(req.body);
  await budgetService.updateBudgetMeta(req.userId, budgetId, {
    name: body.name,
    resetType: body.reset_type,
    resetSchedule: body.reset_schedule ?? null,
    version: body.version,
  });
  res.json({ ok: true });
}

export async function upsertCategory(req: AuthedRequest, res: Response): Promise<void> {
  const budgetId = BigInt(req.params.id);
  const body = categoryUpsertSchema.parse(req.body);
  await budgetService.upsertCategory(req.userId, budgetId, {
    id: body.id,
    name: body.name,
    estimated: body.estimated,
    version: body.version,
  });
  const data = await budgetService.listBudgetsWithCategories(req.userId);
  res.json({ budgets: data });
}

export async function deleteCategory(req: AuthedRequest, res: Response): Promise<void> {
  const budgetId = BigInt(req.params.budgetId);
  const categoryId = BigInt(req.params.categoryId);
  await budgetService.deleteCategory(req.userId, budgetId, categoryId);
  res.json({ ok: true });
}

export async function create(req: AuthedRequest, res: Response): Promise<void> {
  const body = createBudgetSchema.parse(req.body);
  const result = await budgetCreateService.createBudget(
    req.userId,
    body.name,
    body.reset_type,
    body.reset_schedule ?? null
  );
  res.status(201).json({ budget: result });
}

export async function reallocate(req: AuthedRequest, res: Response): Promise<void> {
  const body = reallocateSchema.parse(req.body);
  await budgetService.reallocateBetweenBudgets(
    req.userId,
    body.fromBudgetId,
    body.toBudgetId,
    body.amount
  );
  res.json({ ok: true });
}
