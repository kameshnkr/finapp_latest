import { Router } from "express";
import * as budgetController from "../controllers/budgetController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const budgetRouter = Router();

budgetRouter.use(authMiddleware);

budgetRouter.get(
  "/",
  asyncHandler((req, res) =>
    budgetController.list(req as AuthedRequest, res)
  )
);

budgetRouter.post(
  "/",
  asyncHandler((req, res) =>
    budgetController.create(req as AuthedRequest, res)
  )
);

budgetRouter.post(
  "/reallocate",
  asyncHandler((req, res) =>
    budgetController.reallocate(req as AuthedRequest, res)
  )
);

budgetRouter.patch(
  "/:id",
  asyncHandler((req, res) =>
    budgetController.updateMeta(req as AuthedRequest, res)
  )
);

budgetRouter.post(
  "/:id/categories",
  asyncHandler((req, res) =>
    budgetController.upsertCategory(req as AuthedRequest, res)
  )
);

budgetRouter.delete(
  "/:budgetId/categories/:categoryId",
  asyncHandler((req, res) =>
    budgetController.deleteCategory(req as AuthedRequest, res)
  )
);
