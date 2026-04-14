import type { Request, Response, NextFunction } from "express";
import { pool } from "../db/pool.js";
import * as sessionRepo from "../repositories/sessionRepository.js";
import { HttpError } from "../utils/errors.js";

export type AuthedRequest = Request & {
  userId: bigint;
  sessionToken: string;
};

export async function authMiddleware(
  req: Request,
  _res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const header = req.headers.authorization;
    const token =
      header?.startsWith("Bearer ") ? header.slice(7) : undefined;
    if (!token) {
      throw new HttpError(401, "Missing session token");
    }
    const session = await sessionRepo.findSessionByToken(pool, token);
    if (!session) {
      throw new HttpError(401, "Invalid session");
    }
    (req as AuthedRequest).userId = session.user_id;
    (req as AuthedRequest).sessionToken = token;
    next();
  } catch (e) {
    next(e);
  }
}
