import { Router } from "express";
import * as accountController from "../controllers/accountController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const accountRouter = Router();

accountRouter.use(authMiddleware);

accountRouter.get(
  "/",
  asyncHandler((req, res) =>
    accountController.list(req as AuthedRequest, res)
  )
);

accountRouter.post(
  "/",
  asyncHandler((req, res) =>
    accountController.create(req as AuthedRequest, res)
  )
);

accountRouter.patch(
  "/:id",
  asyncHandler((req, res) =>
    accountController.update(req as AuthedRequest, res)
  )
);

accountRouter.post(
  "/:id/reallocate",
  asyncHandler((req, res) =>
    accountController.reallocate(req as AuthedRequest, res)
  )
);

accountRouter.post(
  "/:id/adjustBalance",
  asyncHandler((req, res) =>
    accountController.adjustBalance(req as AuthedRequest, res)
  )
);
