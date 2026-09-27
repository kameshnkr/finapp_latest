import { Router } from "express";
import * as accountController from "../controllers/investmentsAccountController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsAccountRouter = Router();

investmentsAccountRouter.use(authMiddleware);

investmentsAccountRouter.get(
  "/",
  asyncHandler((req, res) => accountController.list(req as AuthedRequest, res))
);

investmentsAccountRouter.post(
  "/",
  asyncHandler((req, res) => accountController.create(req as AuthedRequest, res))
);

investmentsAccountRouter.patch(
  "/:id",
  asyncHandler((req, res) => accountController.rename(req as AuthedRequest, res))
);
