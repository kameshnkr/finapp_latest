import type { Request, Response } from "express";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import * as authService from "../services/authService.js";
import * as userRepo from "../repositories/userRepository.js";
import { pool } from "../db/pool.js";

const loginSchema = z.object({
  email: z.string().email(),
  otp: z.string().min(1),
});

export async function login(req: Request, res: Response): Promise<void> {
  console.log("login", req.body);
  const body = loginSchema.parse(req.body);
  const result = await authService.loginWithStaticOtp(body.email, body.otp);
  res.json({
    token: result.token,
    user: { id: result.userId.toString(), email: result.email },
  });
}

export async function logout(req: AuthedRequest, res: Response): Promise<void> {
  await authService.logout(req.sessionToken);
  res.status(204).end();
}

export async function me(req: AuthedRequest, res: Response): Promise<void> {
  const user = await userRepo.findUserById(pool, req.userId);
  if (!user) {
    res.status(404).json({ error: "User not found" });
    return;
  }
  res.json({ id: user.id.toString(), email: user.email });
}
