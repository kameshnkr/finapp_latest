import { pool } from "../db/pool.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import type { InvestmentsPotRow } from "../repositories/investmentsPotRepository.js";
import { HttpError } from "../utils/errors.js";

// Create/rename-description for user-owned Pots — mirrors
// investmentsAccountService.ts's createAccount/renameAccount exactly
// (same validation, same 409-on-duplicate-name behavior via the
// UNIQUE(user_id, name) constraint, same optimistic-concurrency pattern).
// Read (list + current value) stays in investmentsPortfolioService.ts,
// which this doesn't touch.

function serialize(p: InvestmentsPotRow) {
  return {
    id: p.id.toString(),
    name: p.name,
    description: p.description,
    iconKey: p.icon_key,
    status: p.status,
    version: p.version,
    createdAt: p.created_at.toISOString(),
    updatedAt: p.updated_at.toISOString(),
  };
}

export async function createPot(
  userId: bigint,
  name: string,
  description: string | null,
  iconKey: string
) {
  try {
    const row = await potRepo.insertPot(pool, userId, name, description, iconKey);
    return serialize(row);
  } catch (e: unknown) {
    if ((e as { code?: string })?.code === "23505") {
      throw new HttpError(409, "A Pot with this name already exists");
    }
    throw e;
  }
}

export async function updatePot(
  userId: bigint,
  potId: bigint,
  name: string,
  description: string | null,
  iconKey: string,
  version: number
) {
  const existing = await potRepo.getPotForUser(pool, userId, potId);
  if (!existing) throw new HttpError(404, "Pot not found");
  if (existing.version !== version) throw new HttpError(409, "Version conflict");

  try {
    const row = await potRepo.updatePot(pool, userId, potId, name, description, iconKey, version);
    if (!row) throw new HttpError(409, "Version conflict");
    return serialize(row);
  } catch (e: unknown) {
    if (e instanceof HttpError) throw e;
    if ((e as { code?: string })?.code === "23505") {
      throw new HttpError(409, "A Pot with this name already exists");
    }
    throw e;
  }
}
