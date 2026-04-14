import { Router } from "express";
import * as transactionController from "../controllers/transactionController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const transactionRouter = Router();

transactionRouter.use(authMiddleware);

transactionRouter.get(
  "/drafts",
  asyncHandler((req, res) =>
    transactionController.listDrafts(req as AuthedRequest, res)
  )
);

transactionRouter.get(
  "/settled",
  asyncHandler((req, res) =>
    transactionController.listSettled(req as AuthedRequest, res)
  )
);

transactionRouter.post(
  "/drafts",
  asyncHandler((req, res) =>
    transactionController.createDraft(req as AuthedRequest, res)
  )
);

transactionRouter.post(
  "/settle",
  asyncHandler((req, res) =>
    transactionController.settle(req as AuthedRequest, res)
  )
);

transactionRouter.patch(
  "/:id",
  asyncHandler((req, res) =>
    transactionController.updateSettled(req as AuthedRequest, res)
  )
);
