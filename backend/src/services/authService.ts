import { pool } from "../db/pool.js";
import { env } from "../config/env.js";
import * as userRepo from "../repositories/userRepository.js";
import * as sessionRepo from "../repositories/sessionRepository.js";
import { ensureDefaultDataForUser } from "./bootstrapService.js";
import { HttpError } from "../utils/errors.js";

export async function loginWithStaticOtp(
  email: string,
  otp: string
): Promise<{ token: string; userId: bigint; email: string }> {
  if (otp !== env.staticOtp) {
    throw new HttpError(401, "Invalid OTP");
  }
  const normalized = email.trim().toLowerCase();
  if (!normalized) throw new HttpError(400, "Email required");
  console.log("loginWithStaticOtp Before findUserByEmail", normalized);
  let user = await userRepo.findUserByEmail(pool, normalized);
  console.log("loginWithStaticOtp After findUserByEmail", normalized);
  if (!user) {
    user = await userRepo.createUser(pool, normalized);
  }
  await ensureDefaultDataForUser(user.id);
  const session = await sessionRepo.createSession(pool, user.id);
  return { token: session.token, userId: user.id, email: user.email };
}

export async function logout(token: string): Promise<void> {
  await sessionRepo.deleteSessionByToken(pool, token);
}
