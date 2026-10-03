import { Router } from "express";
import * as priceController from "../controllers/investmentsPriceController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsPriceRouter = Router();

investmentsPriceRouter.use(authMiddleware);

investmentsPriceRouter.post(
  "/refresh",
  asyncHandler((req, res) => priceController.refresh(req as AuthedRequest, res))
);
