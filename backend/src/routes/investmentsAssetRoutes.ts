import { Router } from "express";
import * as assetController from "../controllers/investmentsAssetController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsAssetRouter = Router();

investmentsAssetRouter.use(authMiddleware);

investmentsAssetRouter.get(
  "/",
  asyncHandler((req, res) => assetController.list(req as AuthedRequest, res))
);
