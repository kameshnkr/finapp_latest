import { Router } from "express";
import * as reallocationController from "../controllers/investmentsReallocationController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const investmentsReallocationRouter = Router();

investmentsReallocationRouter.use(authMiddleware);

investmentsReallocationRouter.get(
  "/",
  asyncHandler((req, res) => reallocationController.getData(req as AuthedRequest, res))
);

investmentsReallocationRouter.post(
  "/",
  asyncHandler((req, res) => reallocationController.execute(req as AuthedRequest, res))
);
