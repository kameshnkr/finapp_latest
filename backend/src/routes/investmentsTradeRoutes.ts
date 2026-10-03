import { Router } from "express";
import * as tradeController from "../controllers/investmentsTradeController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsTradeRouter = Router();

investmentsTradeRouter.use(authMiddleware);

investmentsTradeRouter.get(
  "/unlabeled",
  asyncHandler((req, res) => tradeController.listUnlabeled(req as AuthedRequest, res))
);

investmentsTradeRouter.get(
  "/labeled",
  asyncHandler((req, res) => tradeController.listLabeled(req as AuthedRequest, res))
);

investmentsTradeRouter.post(
  "/allocate",
  asyncHandler((req, res) => tradeController.allocate(req as AuthedRequest, res))
);
