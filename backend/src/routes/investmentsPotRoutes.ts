import { Router } from "express";
import * as potController from "../controllers/investmentsPotController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsPotRouter = Router();

investmentsPotRouter.use(authMiddleware);

investmentsPotRouter.get(
  "/",
  asyncHandler((req, res) => potController.list(req as AuthedRequest, res))
);

investmentsPotRouter.post(
  "/",
  asyncHandler((req, res) => potController.create(req as AuthedRequest, res))
);

investmentsPotRouter.patch(
  "/:id",
  asyncHandler((req, res) => potController.update(req as AuthedRequest, res))
);
