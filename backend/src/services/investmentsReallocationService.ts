import { pool } from "../db/pool.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as assetRepo from "../repositories/investmentsAssetRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import { HttpError } from "../utils/errors.js";

// Matches investments_pot_positions/investments_transactions' NUMERIC(20,6)
// precision — same tolerance convention as investmentsAllocationService.ts.
const UNITS_EPSILON = 0.000001;

export const REALLOCATION_INSUFFICIENT_UNITS_MESSAGE =
  "One of the source Pots no longer has enough units to complete this reallocation. Please refresh and try again.";

function n(s: string | null | undefined): number {
  if (s === null || s === undefined) return 0;
  const v = parseFloat(s);
  return Number.isFinite(v) ? v : 0;
}

function money(v: number): string {
  return v.toFixed(2);
}

export type ReallocationPositionEntry = {
  accountAssetId: string;
  accountName: string;
  assetName: string;
  assetClass: string;
  units: string;
  price: string;
  value: string;
};

export type ReallocationPotEntry = {
  id: string;
  name: string;
  currentValue: string;
  positions: ReallocationPositionEntry[];
};

/**
 * Data needed to build the "Modify Allocation" guided UI entirely client-
 * side: every ACTIVE pot's current value plus its full per-(account, asset)
 * position breakdown (units, latest price, computed rs value). The client
 * uses this to compute every default split/bound/cap locally — no further
 * round-trips needed until the final POST /reallocation submits the fully
 * resolved movements. See investments_pot_amounts_v2.log's "UI Flow v3".
 *
 * Assets with no cached latest price are excluded entirely from every pot's
 * breakdown — there is no reliable rs <-> units conversion without one
 * (mirrors how such assets already contribute 0 to currentValue elsewhere).
 * Zero-unit positions are excluded too (a pot not holding an asset at all).
 */
export async function getReallocationData(userId: bigint): Promise<{ pots: ReallocationPotEntry[] }> {
  const [pots, assetDetails, potPositions] = await Promise.all([
    potRepo.listActivePotsForUser(pool, userId),
    assetRepo.listAccountAssetDetailsForUser(pool, userId),
    positionRepo.listPotPositionDetailsForUser(pool, userId),
  ]);

  // account_asset_id -> display/price info, for O(1) lookups while building
  // each pot's breakdown below. price is null until a price refresh has run.
  const assetByAccountAssetId = new Map<
    string,
    { accountName: string; assetName: string; assetClass: string; price: number | null }
  >();
  for (const d of assetDetails) {
    assetByAccountAssetId.set(d.account_asset_id.toString(), {
      accountName: d.account_name,
      assetName: d.asset_name,
      assetClass: d.asset_class,
      price: d.latest_price !== null ? n(d.latest_price) : null,
    });
  }

  const positionsByPotId = new Map<string, ReallocationPositionEntry[]>();
  for (const pp of potPositions) {
    const units = n(pp.units);
    if (units <= 0) continue;

    const asset = assetByAccountAssetId.get(pp.account_asset_id.toString());
    if (!asset || asset.price === null) continue; // no price -> excluded entirely

    const key = pp.pot_id.toString();
    const list = positionsByPotId.get(key) ?? [];
    list.push({
      accountAssetId: pp.account_asset_id.toString(),
      accountName: asset.accountName,
      assetName: asset.assetName,
      assetClass: asset.assetClass,
      units: units.toFixed(6),
      price: asset.price.toFixed(4),
      value: money(units * asset.price),
    });
    positionsByPotId.set(key, list);
  }

  return {
    pots: pots.map((p) => {
      const positions = positionsByPotId.get(p.id.toString()) ?? [];
      const currentValue = positions.reduce((sum, pos) => sum + n(pos.value), 0);
      return {
        id: p.id.toString(),
        name: p.name,
        currentValue: money(currentValue),
        positions,
      };
    }),
  };
}

export type ReallocationMovementInput = {
  accountAssetId: string;
  fromPotId: string;
  toPotId: string;
  /** Decimal string, > 0 — the exact units to move for this one asset/pot pair. */
  units: string;
};

type ParsedMovement = {
  accountAssetId: bigint;
  fromPotId: bigint;
  toPotId: bigint;
  units: string; // normalized to 6 decimals
};

/**
 * Validates and atomically applies a fully-resolved set of pot-to-pot unit
 * movements (already computed client-side per the guided UI flow — this is
 * the one place the server re-validates everything as the source of truth).
 *
 * Deliberately a plain "-X units here, +X units there" direct adjustment of
 * investments_pot_positions — NO rows are created in investments_transactions
 * and investments_positions (the account-level total per asset) is never
 * touched, since a reallocation only ever moves POT ATTRIBUTION, never real
 * holdings. See investments_pot_amounts_v2.log for the full design rationale
 * (chosen over a Sell+Buy ledger-transaction approach).
 *
 * Mirrors investmentsAllocationService.allocateTransactions' safety pattern
 * exactly: a single pre-check of aggregated requested deductions per
 * (pot, asset) BEFORE any write, then every delta applied inside one DB
 * transaction — either the whole reallocation lands, or nothing changes.
 */
export async function executeReallocation(
  userId: bigint,
  movements: ReallocationMovementInput[]
): Promise<{ movedCount: number }> {
  if (movements.length === 0) {
    throw new HttpError(400, "No movements specified");
  }

  const parsed: ParsedMovement[] = movements.map((m) => {
    const units = parseFloat(m.units);
    if (!Number.isFinite(units) || units <= 0) {
      throw new HttpError(400, "Each movement's units must be a positive number");
    }
    let fromPotId: bigint, toPotId: bigint, accountAssetId: bigint;
    try {
      fromPotId = BigInt(m.fromPotId);
      toPotId = BigInt(m.toPotId);
      accountAssetId = BigInt(m.accountAssetId);
    } catch {
      throw new HttpError(400, "Invalid pot or asset id");
    }
    if (fromPotId === toPotId) {
      throw new HttpError(400, "A movement's source and target Pot must be different");
    }
    return { accountAssetId, fromPotId, toPotId, units: units.toFixed(6) };
  });

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    // Every referenced Pot must belong to this user and be ACTIVE — archived
    // pots are never a valid source or target.
    const potIds = Array.from(new Set(parsed.flatMap((m) => [m.fromPotId, m.toPotId]).map(String))).map(BigInt);
    const pots = await potRepo.getPotsForUser(client, userId, potIds);
    if (pots.length !== potIds.length) {
      throw new HttpError(404, "One or more Pots not found");
    }
    for (const p of pots) {
      if (p.status !== "ACTIVE") {
        throw new HttpError(400, `Pot "${p.name}" is archived and can't be used in a reallocation`);
      }
    }

    // Every referenced account-asset must belong to this user.
    const accountAssetIds = Array.from(new Set(parsed.map((m) => m.accountAssetId.toString()))).map(BigInt);
    for (const id of accountAssetIds) {
      const row = await assetRepo.getAccountAssetForUser(client, userId, id);
      if (!row) {
        throw new HttpError(404, "One or more assets not found");
      }
    }

    // ── Mandatory sufficiency guard ── aggregate requested deduction per
    // (fromPotId, accountAssetId) BEFORE writing anything, so a set of
    // movements that's fine individually but not in aggregate (e.g. 2
    // movements pulling the same asset out of the same pot) is still caught
    // before any partial write happens. Exactly the same shape as the
    // real-trade allocation SELL guard.
    const requestByKey = new Map<string, number>();
    for (const m of parsed) {
      const key = `${m.fromPotId}|${m.accountAssetId}`;
      requestByKey.set(key, (requestByKey.get(key) ?? 0) + parseFloat(m.units));
    }
    for (const [key, requestedUnits] of requestByKey) {
      const [potIdStr, accountAssetIdStr] = key.split("|") as [string, string];
      const currentUnits = await positionRepo.getPotPositionUnits(
        client,
        userId,
        BigInt(potIdStr),
        BigInt(accountAssetIdStr)
      );
      if (requestedUnits > currentUnits + UNITS_EPSILON) {
        throw new HttpError(400, REALLOCATION_INSUFFICIENT_UNITS_MESSAGE);
      }
    }

    // ── Commit: apply every delta — source loses units, target gains the
    // exact same units, per movement. Never touches investments_positions. ──
    for (const m of parsed) {
      await positionRepo.adjustPotPosition(client, userId, m.fromPotId, m.accountAssetId, `-${m.units}`);
      await positionRepo.adjustPotPosition(client, userId, m.toPotId, m.accountAssetId, m.units);
    }

    await client.query("COMMIT");
    return { movedCount: parsed.length };
  } catch (e) {
    await client.query("ROLLBACK");
    // Defensive backstop: even if the pre-check above somehow missed a race,
    // the DB-level CHECK (units >= 0) on investments_pot_positions is the
    // hard invariant. Translate that into the same friendly message.
    if (isPotUnitsCheckViolation(e)) {
      throw new HttpError(400, REALLOCATION_INSUFFICIENT_UNITS_MESSAGE);
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
