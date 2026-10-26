import { Router } from "express";
import * as reallocationController from "../controllers/bankingReallocationController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const bankingReallocationRouter = Router();

bankingReallocationRouter.use(authMiddleware);

bankingReallocationRouter.get(
  "/",
  asyncHandler((req, res) => reallocationController.getData(req as AuthedRequest, res))
);

bankingReallocationRouter.post(
  "/",
  asyncHandler((req, res) => reallocationController.execute(req as AuthedRequest, res))
);
