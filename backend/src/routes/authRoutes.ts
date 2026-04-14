import { Router } from "express";
import * as authController from "../controllers/authController.js";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";

export const authRouter = Router();

authRouter.post("/login", asyncHandler(authController.login));

authRouter.post(
  "/logout",
  authMiddleware,
  asyncHandler((req, res) =>
    authController.logout(req as AuthedRequest, res)
  )
);

authRouter.get(
  "/me",
  authMiddleware,
  asyncHandler((req, res) => authController.me(req as AuthedRequest, res))
);
