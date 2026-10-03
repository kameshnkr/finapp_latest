import { pool } from "../db/pool.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";

const DEFAULT_POTS: { name: string; description: string }[] = [
  { name: "Retirement", description: "Long-term wealth for retirement." },
  { name: "Child Education", description: "Savings for future child education." },
  {
    name: "Savings - Real Estate Purchase",
    description: "Savings for a future real estate purchase.",
  },
  { name: "General", description: "General-purpose investments." },
];

const DEFAULT_ACCOUNT_NAMES: string[] = ["My Demat Account 1", "My Demat Account 2"];

/**
 * Lazily creates default Investment Pots + Accounts for a user on first
 * access to any Investments endpoint. Idempotent + transactional, mirroring
 * Banking's ensureDefaultDataForUser — but called lazily from the Investments
 * read endpoints rather than at login, to avoid touching authService.ts.
 */
export async function ensureDefaultInvestmentsDataForUser(userId: bigint): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const potCount = await potRepo.countPotsForUser(client, userId);
    const accountCount = await accountRepo.countAccountsForUser(client, userId);

    if (potCount >= 1 && accountCount >= 1) {
      await client.query("COMMIT");
      return;
    }

    // insertPotIfNotExists/insertAccountIfNotExists (ON CONFLICT DO NOTHING)
    // rather than the plain insert — the count-check above is inherently
    // racy under concurrent requests (e.g. the Home tab's 3 parallel
    // first-load fetches for a brand-new user can all pass potCount===0
    // before any of them commits), so the actual inserts must be
    // conflict-safe on their own, not just gated by the earlier count check.
    if (potCount === 0) {
      for (const p of DEFAULT_POTS) {
        await potRepo.insertPotIfNotExists(client, userId, p.name, p.description);
      }
    }

    if (accountCount === 0) {
      for (const name of DEFAULT_ACCOUNT_NAMES) {
        await accountRepo.insertAccountIfNotExists(client, userId, name, null);
      }
    }

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
