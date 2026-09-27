import { pool } from "../db/pool.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import type { InvestmentsAccountRow } from "../repositories/investmentsAccountRepository.js";
import { ensureDefaultInvestmentsDataForUser } from "./investmentsBootstrapService.js";
import { HttpError } from "../utils/errors.js";

function serialize(a: InvestmentsAccountRow) {
  return {
    id: a.id.toString(),
    name: a.name,
    brokerName: a.broker_name,
    accountIdentifier: a.account_identifier,
    status: a.status,
    version: a.version,
    createdAt: a.created_at.toISOString(),
    updatedAt: a.updated_at.toISOString(),
  };
}

export async function listAccounts(userId: bigint) {
  await ensureDefaultInvestmentsDataForUser(userId);
  const rows = await accountRepo.listActiveAccountsForUser(pool, userId);
  return rows.map(serialize);
}

export async function createAccount(
  userId: bigint,
  name: string,
  brokerName: string | null
) {
  try {
    const row = await accountRepo.insertAccount(pool, userId, name, brokerName);
    return serialize(row);
  } catch (e: unknown) {
    if ((e as { code?: string })?.code === "23505") {
      throw new HttpError(409, "An account with this name already exists");
    }
    throw e;
  }
}

export async function renameAccount(
  userId: bigint,
  accountId: bigint,
  newName: string,
  version: number
) {
  const existing = await accountRepo.getAccountForUser(pool, userId, accountId);
  if (!existing) throw new HttpError(404, "Account not found");
  if (existing.version !== version) throw new HttpError(409, "Version conflict");

  try {
    const row = await accountRepo.renameAccount(pool, userId, accountId, newName, version);
    if (!row) throw new HttpError(409, "Version conflict");
    return serialize(row);
  } catch (e: unknown) {
    if (e instanceof HttpError) throw e;
    if ((e as { code?: string })?.code === "23505") {
      throw new HttpError(409, "An account with this name already exists");
    }
    throw e;
  }
}
