import { pool } from "../db/pool.js";
import * as txRepo from "../repositories/investmentsTransactionRepository.js";
import * as allocationRepo from "../repositories/investmentsAllocationRepository.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import { HttpError } from "../utils/errors.js";

export type AllocationInput = { potId: string; percentage: number };

// Percentages are user-entered decimals (e.g. 33.33); this tolerance absorbs
// float/rounding noise when checking that a set of splits sums to 100.
const PERCENTAGE_SUM_TOLERANCE = 0.01;

// Absolute unit tolerance when checking a Pot's sell-sufficiency, matching
// the precision investments_transactions.units/investments_pot_positions.units
// are stored at (NUMERIC(20,6)).
const UNITS_EPSILON = 0.000001;

export const SELL_INSUFFICIENT_UNITS_MESSAGE =
  "There aren't enough units in this Pot to assign this sell transaction. Assign the corresponding buy transaction(s) to this Pot first.";

function n(s: string): number {
  return parseFloat(s);
}

/**
 * Labels one or more Unlabeled trades by allocating them to one or more
 * Pots. Supports exactly 3 flows (per the product spec):
 *   1. single trade  → single Pot   (one allocation, 100%)
 *   2. multiple trades → single Pot (one allocation, 100%, applied to every trade)
 *   3. single trade  → multiple Pots (percentages summing to 100)
 * "multiple trades → multiple Pots" is deliberately rejected — it has no
 * unambiguous way to say which trade gets which slice of which Pot.
 *
 * All validation, the mandatory SELL sufficiency check, and every resulting
 * write happen inside one DB transaction — either every trade in the
 * request becomes ALLOCATED with matching Pot-position deltas, or nothing
 * changes at all.
 */
export async function allocateTransactions(
  userId: bigint,
  transactionIds: bigint[],
  allocations: AllocationInput[]
): Promise<{ allocatedCount: number }> {
  if (transactionIds.length === 0) {
    throw new HttpError(400, "No trades specified");
  }
  if (allocations.length === 0) {
    throw new HttpError(400, "No Pot allocations specified");
  }
  if (transactionIds.length > 1 && allocations.length > 1) {
    throw new HttpError(
      400,
      "Allocating multiple trades to multiple Pots in one request isn't supported. " +
        "Either allocate multiple trades to a single Pot, or a single trade across multiple Pots."
    );
  }

  const potIds = allocations.map((a) => BigInt(a.potId));
  if (new Set(potIds.map(String)).size !== potIds.length) {
    throw new HttpError(400, "The same Pot was specified more than once");
  }
  for (const a of allocations) {
    if (!Number.isFinite(a.percentage) || a.percentage <= 0 || a.percentage > 100) {
      throw new HttpError(400, "Each Pot allocation percentage must be greater than 0 and at most 100");
    }
  }
  const percentageSum = allocations.reduce((s, a) => s + a.percentage, 0);
  if (Math.abs(percentageSum - 100) > PERCENTAGE_SUM_TOLERANCE) {
    throw new HttpError(400, `Pot allocation percentages must sum to 100 (got ${percentageSum.toFixed(2)})`);
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const trades = await txRepo.lockTransactionsForUser(client, userId, transactionIds);
    if (trades.length !== transactionIds.length) {
      throw new HttpError(404, "One or more trades not found");
    }
    for (const t of trades) {
      if (t.allocation_status !== "UNALLOCATED") {
        throw new HttpError(400, `Trade ${t.id} is already allocated`);
      }
    }

    const pots = await potRepo.getPotsForUser(client, userId, potIds);
    if (pots.length !== potIds.length) {
      throw new HttpError(404, "One or more Pots not found");
    }
    for (const p of pots) {
      if (p.status !== "ACTIVE") {
        throw new HttpError(400, `Pot "${p.name}" is archived and can't receive new allocations`);
      }
    }

    // ── Mandatory SELL guard ────────────────────────────────────────────────
    // Sum the units EVERY sell trade in this batch would withdraw from EACH
    // target Pot (grouped by (pot, account_asset) — a bulk "trades → single
    // Pot" request can touch several different assets at once) and check
    // that sum against the Pot's *current* position before writing anything.
    // This must be a single pre-check over the whole batch, not one check
    // per trade, so a batch that's fine trade-by-trade but not in aggregate
    // (e.g. 2 sells of the same asset to the same Pot, each individually
    // under the current balance but not together) is still caught before
    // any partial write happens.
    const sellRequestByKey = new Map<string, number>(); // "potId|accountAssetId" -> units
    for (const t of trades) {
      if (t.transaction_type !== "SELL") continue;
      const tradeUnits = n(t.units);
      for (const a of allocations) {
        const units = tradeUnits * (a.percentage / 100);
        const key = `${a.potId}|${t.account_asset_id}`;
        sellRequestByKey.set(key, (sellRequestByKey.get(key) ?? 0) + units);
      }
    }

    for (const [key, requestedUnits] of sellRequestByKey) {
      const [potIdStr, accountAssetIdStr] = key.split("|") as [string, string];
      const currentUnits = await positionRepo.getPotPositionUnits(
        client,
        userId,
        BigInt(potIdStr),
        BigInt(accountAssetIdStr)
      );
      if (requestedUnits > currentUnits + UNITS_EPSILON) {
        throw new HttpError(400, SELL_INSUFFICIENT_UNITS_MESSAGE);
      }
    }

    // ── Commit: one allocation row + one Pot-position delta per (trade, pot) ─
    for (const t of trades) {
      const tradeUnits = n(t.units);
      for (const a of allocations) {
        const potId = BigInt(a.potId);
        const allocatedUnits = (tradeUnits * (a.percentage / 100)).toFixed(6);

        await allocationRepo.insertAllocation(client, userId, t.id, potId, a.percentage, allocatedUnits);

        const delta = t.transaction_type === "BUY" ? allocatedUnits : `-${allocatedUnits}`;
        await positionRepo.adjustPotPosition(client, userId, potId, t.account_asset_id, delta);
      }
    }

    await txRepo.markAllocated(client, transactionIds);

    await client.query("COMMIT");
    return { allocatedCount: trades.length };
  } catch (e) {
    await client.query("ROLLBACK");
    // Defensive backstop: even if the pre-check above somehow missed a race
    // (e.g. a concurrent allocation to the same Pot committed in between),
    // the DB-level CHECK (units >= 0) on investments_pot_positions is the
    // hard invariant. Translate that raw constraint violation into the same
    // user-facing message rather than a generic 500.
    if (isPotUnitsCheckViolation(e)) {
      throw new HttpError(400, SELL_INSUFFICIENT_UNITS_MESSAGE);
    }
    throw e;
  } finally {
    client.release();
  }
}

function isPotUnitsCheckViolation(e: unknown): boolean {
  const err = e as { code?: string; constraint?: string } | null;
  return err?.code === "23514" && err?.constraint === "investments_pot_positions_units_check";
}
