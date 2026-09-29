import { readFileSync, unlinkSync } from "fs";
import { pool } from "../db/pool.js";
import * as jobRepo from "../repositories/investmentsUploadJobRepository.js";
import * as assetRepo from "../repositories/investmentsAssetRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import * as txRepo from "../repositories/investmentsTransactionRepository.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import {
  parseHoldingsFile,
  parseTradeBookFile,
  extractAccountIdentity,
  type RawHoldingEntry,
  type RawTradeEntry,
} from "./investmentsLlmParsingService.js";
import { validateTradeBatch } from "./investmentsValidationService.js";
import { readWorkbookAllSheets, buildIdentitySnippet } from "./investmentsExcelService.js";
import {
  reconcileAssetPositions,
  type ReconciliationInput,
  type ReconciliationMismatch,
} from "./investmentsReconciliationService.js";
import {
  computeInvestmentsFingerprint,
  computeReconciliationDummyFingerprint,
} from "../utils/investmentsFingerprint.js";
import { HttpError } from "../utils/errors.js";
import type { InvestmentsAssetClass } from "../types/investmentsDomain.js";

// ── Serializable shapes stored in investments_upload_jobs.result (JSONB) ────

type SerializedPendingTransaction = {
  accountAssetId: string;
  isin: string;
  assetName: string;
  transactionType: "BUY" | "SELL";
  units: string;
  price: string;
  amount: string;
  transactionDate: string;
  sourceReferenceId: string | null;
  fingerprint: string;
};

type AwaitingConfirmationPayload = {
  accountId: string;
  identity: { brokerName: string | null; accountIdentifier: string | null };
  mismatches: ReconciliationMismatch[];
  pendingTransactions: SerializedPendingTransaction[];
  totalExtracted: number;
  duplicatesSkipped: number;
};

// ── Grouping helpers ──────────────────────────────────────────────────────────

// Relative tolerance used to decide whether two reported unit counts for
// the same ISIN are "the same holding restated" vs. genuinely different
// (additive) balances. 0.1% comfortably covers float/rounding noise while
// being far tighter than any real split-balance difference would be.
const DUPLICATE_UNITS_RELATIVE_TOLERANCE = 0.001;

/**
 * Merges holdings entries by ISIN. The same ISIN can legitimately appear
 * more than once in a Holdings export for two very different reasons, and
 * this function must tell them apart WITHOUT relying on which sheet/banner
 * text a row came from (sheet naming conventions are broker-specific and
 * cannot be exhaustively enumerated):
 *
 *   1. A genuine SPLIT balance (e.g. "Free" + "Pledged" quantity rows for
 *      the same holding) — these are two DIFFERENT numbers that must be
 *      SUMMED to get the true total.
 *   2. The SAME holding restated in more than one place (e.g. a
 *      "Combined"/"Consolidated" rollup sheet repeating a per-asset-class
 *      sheet's rows, under whatever name that broker gives it) — these
 *      report the SAME number twice and must NOT be summed, or the holding
 *      is silently doubled.
 *
 * We distinguish the two cases by comparing the reported unit counts
 * themselves: if they match within a small tolerance, it's case 2 (keep
 * one); if they differ meaningfully, it's case 1 (sum). This reacts to the
 * actual data rather than to a specific broker's sheet-naming conventions,
 * so it generalizes to broker exports this pipeline hasn't been tested
 * against yet.
 */
function mergeHoldingsByIsin(entries: RawHoldingEntry[]): Map<string, RawHoldingEntry> {
  const map = new Map<string, RawHoldingEntry>();
  for (const e of entries) {
    const existing = map.get(e.isin);
    if (!existing) {
      map.set(e.isin, { ...e });
      continue;
    }

    const tolerance = Math.max(existing.units, e.units) * DUPLICATE_UNITS_RELATIVE_TOLERANCE;
    const isLikelyDuplicateRestatement = Math.abs(existing.units - e.units) <= tolerance;

    if (isLikelyDuplicateRestatement) {
      console.log(
        `[investments][holdings] ISIN ${e.isin} appears more than once with matching units ` +
          `(${existing.units} ≈ ${e.units}) — treating as a duplicate restatement (e.g. a rollup ` +
          `sheet), not summing.`
      );
      // Keep the existing entry as-is; just backfill price if missing.
    } else {
      console.log(
        `[investments][holdings] ISIN ${e.isin} appears more than once with different units ` +
          `(${existing.units} vs ${e.units}) — treating as a genuine split balance (e.g. Free + ` +
          `Pledged) and summing.`
      );
      existing.units += e.units;
    }
    if (e.price !== null) existing.price = e.price;
    if (e.priceDate !== null) existing.priceDate = e.priceDate;
  }
  return map;
}

type TradeAggregate = {
  buyUnits: number;
  sellUnits: number;
  name: string;
  symbol: string | null;
  assetClass: InvestmentsAssetClass;
  latestDate: string;
};

function sumTradesByIsin(entries: RawTradeEntry[]): Map<string, TradeAggregate> {
  const map = new Map<string, TradeAggregate>();
  for (const e of entries) {
    const cur =
      map.get(e.isin) ??
      ({ buyUnits: 0, sellUnits: 0, name: e.name, symbol: e.symbol, assetClass: e.assetClass, latestDate: e.transactionDate } as TradeAggregate);
    if (e.transactionType === "BUY") cur.buyUnits += e.units;
    else cur.sellUnits += e.units;
    if (e.transactionDate > cur.latestDate) cur.latestDate = e.transactionDate;
    map.set(e.isin, cur);
  }
  return map;
}

function fail(reason: string): never {
  throw new Error(reason);
}

// ── Main async pipeline ───────────────────────────────────────────────────────

export async function processInvestmentsUpload(
  jobId: string,
  userId: bigint,
  accountId: bigint,
  holdingsFilePath: string,
  tradeBookFilePath: string
): Promise<void> {
  try {
    await jobRepo.updateJobStatus(pool, jobId, "PARSING", "Reading holdings file...");
    const holdingsBuffer = readFileSync(holdingsFilePath);
    const holdingsRaw = await parseHoldingsFile(holdingsBuffer, jobId);
    const holdingsByIsin = mergeHoldingsByIsin(holdingsRaw);

    if (holdingsByIsin.size === 0) {
      fail(
        "Could not identify any ISIN-tagged holdings in the uploaded Holdings file. " +
          "Please confirm the file contains an ISIN column."
      );
    }

    await jobRepo.updateJobStatus(pool, jobId, "PARSING", "Reading trade book...");
    const tradeBookBuffer = readFileSync(tradeBookFilePath);
    const { entries: tradeEntries, failedBatches } = await parseTradeBookFile(
      tradeBookBuffer,
      jobId,
      validateTradeBatch
    );

    if (failedBatches.length > 0) {
      const detail = failedBatches
        .map((b) => `${b.label}: ${b.failures.slice(0, 3).join("; ")}`)
        .join(" | ");
      fail(
        `Trade Book failed the amount-consistency check after 1 retry. The upload was not saved. ` +
          `Details: ${detail}`
      );
    }

    if (tradeEntries.length === 0) {
      fail(
        "Could not identify any valid ISIN-tagged trades in the uploaded Trade Book. " +
          "Please confirm the file contains an ISIN column."
      );
    }

    await jobRepo.updateJobStatus(pool, jobId, "RECONCILING", "Reconciling holdings...");

    const tradesByIsin = sumTradesByIsin(tradeEntries);
    const allIsins = new Set<string>([...holdingsByIsin.keys(), ...tradesByIsin.keys()]);

    // ── Resolve (idempotent) asset + account_asset rows for every ISIN ──────
    const isinToAccountAssetId = new Map<string, bigint>();
    const isinToAssetName = new Map<string, string>();

    for (const isin of allIsins) {
      const tradeMeta = tradesByIsin.get(isin);
      const holdingsMeta = holdingsByIsin.get(isin);
      const name = tradeMeta?.name || holdingsMeta?.name || isin;
      const symbol = tradeMeta?.symbol ?? holdingsMeta?.symbol ?? null;
      const assetClass: InvestmentsAssetClass = tradeMeta?.assetClass ?? holdingsMeta?.assetClass ?? "OTHER";

      const asset = await assetRepo.findOrCreateAssetByIsin(pool, {
        isin,
        name,
        symbol,
        assetClass,
        amfiSchemeCode: null,
      });
      const accountAsset = await assetRepo.findOrCreateAccountAsset(pool, userId, accountId, asset.id);

      isinToAccountAssetId.set(isin, accountAsset.id);
      isinToAssetName.set(isin, name);
    }

    // ── Existing units per resolved account_asset ───────────────────────────
    const existingUnitsByIsin = new Map<string, number>();
    for (const isin of allIsins) {
      const accountAssetId = isinToAccountAssetId.get(isin)!;
      const pos = await positionRepo.getPosition(pool, userId, accountAssetId);
      existingUnitsByIsin.set(isin, pos ? parseFloat(pos.units) : 0);
    }

    // ── Build + fingerprint pending trade items, dedup within-file and vs DB ─
    // IMPORTANT: this must happen BEFORE reconciliation. existingUnitsByIsin
    // (above) already reflects every previously-confirmed trade for this
    // account/asset. If a re-uploaded file's trades are exact duplicates of
    // trades already reflected in existingUnits, they must NOT also be
    // counted again in the reconciliation buy/sell sums below — otherwise
    // re-uploading an *unchanged* file would incorrectly report a phantom
    // mismatch (double-counting) and could prompt the user to confirm a
    // bogus reconciliation dummy on top of already-correct positions.
    const seenFingerprints = new Set<string>();
    let duplicatesWithinFile = 0;
    const candidates: SerializedPendingTransaction[] = [];

    for (const e of tradeEntries) {
      const accountAssetId = isinToAccountAssetId.get(e.isin);
      if (!accountAssetId) continue; // defensive; should always resolve

      const units = e.units.toFixed(6);
      const price = e.price.toFixed(4);
      const amount = e.amount.toFixed(2);
      const fingerprint = computeInvestmentsFingerprint({
        accountId,
        isin: e.isin,
        transactionType: e.transactionType,
        units,
        price,
        transactionDate: e.transactionDate,
      });

      if (seenFingerprints.has(fingerprint)) {
        duplicatesWithinFile++;
        continue;
      }
      seenFingerprints.add(fingerprint);

      candidates.push({
        accountAssetId: accountAssetId.toString(),
        isin: e.isin,
        assetName: isinToAssetName.get(e.isin) ?? e.isin,
        transactionType: e.transactionType,
        units,
        price,
        amount,
        transactionDate: e.transactionDate,
        sourceReferenceId: e.tradeId ?? e.orderId ?? null,
        fingerprint,
      });
    }

    const existingFingerprints = await txRepo.findExistingFingerprints(
      pool,
      userId,
      candidates.map((c) => c.fingerprint)
    );
    const newItems = candidates.filter((c) => !existingFingerprints.has(c.fingerprint));
    const duplicatesSkipped = duplicatesWithinFile + (candidates.length - newItems.length);

    // ── Reconciliation — buy/sell sums come ONLY from genuinely-new items ───
    const newBuySellByIsin = new Map<string, { buyUnits: number; sellUnits: number }>();
    for (const item of newItems) {
      const agg = newBuySellByIsin.get(item.isin) ?? { buyUnits: 0, sellUnits: 0 };
      const units = parseFloat(item.units);
      if (item.transactionType === "BUY") agg.buyUnits += units;
      else agg.sellUnits += units;
      newBuySellByIsin.set(item.isin, agg);
    }

    const reconciliationInputs: ReconciliationInput[] = Array.from(allIsins).map((isin) => {
      const holdings = holdingsByIsin.get(isin) ?? null;
      const newSums = newBuySellByIsin.get(isin) ?? null;
      return {
        accountAssetId: isinToAccountAssetId.get(isin)!.toString(),
        isin,
        assetName: isinToAssetName.get(isin) ?? isin,
        existingUnits: existingUnitsByIsin.get(isin) ?? 0,
        buyUnits: newSums?.buyUnits ?? 0,
        sellUnits: newSums?.sellUnits ?? 0,
        holdingsUnits: holdings ? holdings.units : null,
        holdingsPrice: holdings ? holdings.price : null,
      };
    });
    const mismatches = reconcileAssetPositions(reconciliationInputs);

    // ── Best-effort broker/account-identifier extraction (once per job) ─────
    const holdingsSheets = readWorkbookAllSheets(holdingsBuffer);
    const tradeSheets = readWorkbookAllSheets(tradeBookBuffer);
    const identitySnippet = buildIdentitySnippet([...holdingsSheets, ...tradeSheets]);
    const identity = await extractAccountIdentity(identitySnippet, jobId);

    if (mismatches.length > 0) {
      const payload: AwaitingConfirmationPayload = {
        accountId: accountId.toString(),
        identity,
        mismatches,
        pendingTransactions: newItems,
        totalExtracted: tradeEntries.length,
        duplicatesSkipped,
      };
      await jobRepo.setAwaitingConfirmation(pool, jobId, payload as unknown as Record<string, unknown>);
      console.log(
        `[investments][job:${jobId}] ⏸ AWAITING_CONFIRMATION — ${mismatches.length} asset mismatch(es), ` +
          `${newItems.length} pending trade(s)`
      );
      return;
    }

    // ── No mismatches: save directly ─────────────────────────────────────────
    await saveTradesAndUpdatePositions(userId, accountId, newItems, identity);

    await jobRepo.completeJob(pool, jobId, {
      total_extracted: tradeEntries.length,
      total_inserted: newItems.length,
      duplicates_skipped: duplicatesSkipped,
      reconciled_count: 0,
    });
    console.log(
      `[investments][job:${jobId}] ✅ Done — extracted=${tradeEntries.length}, inserted=${newItems.length}, ` +
        `skipped=${duplicatesSkipped}`
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown processing error";
    console.error(`[investments][job:${jobId}] ❌ Failed: ${message}`);
    await jobRepo.failJob(pool, jobId, message);
  } finally {
    try {
      unlinkSync(holdingsFilePath);
    } catch {
      /* non-fatal */
    }
    try {
      unlinkSync(tradeBookFilePath);
    } catch {
      /* non-fatal */
    }
  }
}

/** Inserts trades + applies position deltas inside one DB transaction, then
 * best-effort backfills the account's broker/identifier (no-op if already set). */
async function saveTradesAndUpdatePositions(
  userId: bigint,
  accountId: bigint,
  items: SerializedPendingTransaction[],
  identity: { brokerName: string | null; accountIdentifier: string | null }
): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    for (const item of items) {
      const [inserted] = await txRepo.insertTransactions(client, userId, [
        {
          accountAssetId: BigInt(item.accountAssetId),
          transactionType: item.transactionType,
          units: item.units,
          price: item.price,
          amount: item.amount,
          transactionDate: item.transactionDate,
          sourceReferenceId: item.sourceReferenceId,
          fingerprint: item.fingerprint,
        },
      ]);
      if (!inserted) continue;
      const delta = item.transactionType === "BUY" ? item.units : `-${item.units}`;
      await positionRepo.adjustPosition(client, userId, BigInt(item.accountAssetId), delta);
    }

    await accountRepo.backfillIdentityIfMissing(
      client,
      accountId,
      identity.brokerName,
      identity.accountIdentifier
    );

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

// ── Confirm / Reject (AWAITING_CONFIRMATION resolution) ──────────────────────

export type MismatchResolution = { accountAssetId: string; createDummy: boolean };

export async function confirmInvestmentsUpload(
  userId: bigint,
  jobId: string,
  resolutions: MismatchResolution[]
): Promise<{ totalInserted: number; duplicatesSkipped: number; dummiesCreated: number }> {
  const job = await jobRepo.getJob(pool, jobId, userId);
  if (!job) throw new HttpError(404, "Job not found");
  if (job.status !== "AWAITING_CONFIRMATION") {
    throw new HttpError(409, `Job is not awaiting confirmation (status: ${job.status})`);
  }

  const payload = job.result as unknown as AwaitingConfirmationPayload;
  const accountId = BigInt(payload.accountId);
  const resolutionByAccountAsset = new Map(resolutions.map((r) => [r.accountAssetId, r.createDummy]));

  await jobRepo.updateJobStatus(pool, jobId, "SAVING", "Saving trades...");

  // Re-check fingerprints in case a concurrent upload already inserted some.
  const existingFingerprints = await txRepo.findExistingFingerprints(
    pool,
    userId,
    payload.pendingTransactions.map((t) => t.fingerprint)
  );
  const toInsert = payload.pendingTransactions.filter((t) => !existingFingerprints.has(t.fingerprint));
  const extraSkipped = payload.pendingTransactions.length - toInsert.length;

  const client = await pool.connect();
  let dummiesCreated = 0;
  try {
    await client.query("BEGIN");

    for (const item of toInsert) {
      const [inserted] = await txRepo.insertTransactions(client, userId, [
        {
          accountAssetId: BigInt(item.accountAssetId),
          transactionType: item.transactionType,
          units: item.units,
          price: item.price,
          amount: item.amount,
          transactionDate: item.transactionDate,
          sourceReferenceId: item.sourceReferenceId,
          fingerprint: item.fingerprint,
        },
      ]);
      if (!inserted) continue;
      const delta = item.transactionType === "BUY" ? item.units : `-${item.units}`;
      await positionRepo.adjustPosition(client, userId, BigInt(item.accountAssetId), delta);
    }

    for (const mismatch of payload.mismatches) {
      const wantsDummy = resolutionByAccountAsset.get(mismatch.accountAssetId) ?? false;
      if (!wantsDummy || !mismatch.canCreateDummy || !mismatch.dummyPrice) continue;

      const accountAssetId = BigInt(mismatch.accountAssetId);
      // Latest trade date for this asset among pending trades, else today.
      const latestForAsset = payload.pendingTransactions
        .filter((t) => t.accountAssetId === mismatch.accountAssetId)
        .reduce((max, t) => (t.transactionDate > max ? t.transactionDate : max), "");
      const transactionDate = latestForAsset || new Date().toISOString().slice(0, 10);

      const dummyFingerprint = computeReconciliationDummyFingerprint({
        accountId,
        accountAssetId,
        isin: mismatch.isin,
        transactionType: mismatch.dummyType,
        units: mismatch.dummyUnits,
        transactionDate,
      });

      const alreadyExists = await txRepo.findExistingFingerprints(client, userId, [dummyFingerprint]);
      if (alreadyExists.has(dummyFingerprint)) continue;

      const amount = (parseFloat(mismatch.dummyUnits) * parseFloat(mismatch.dummyPrice)).toFixed(2);
      const [inserted] = await txRepo.insertTransactions(client, userId, [
        {
          accountAssetId,
          transactionType: mismatch.dummyType,
          units: mismatch.dummyUnits,
          price: mismatch.dummyPrice,
          amount,
          transactionDate,
          sourceReferenceId: null,
          fingerprint: dummyFingerprint,
          source: "RECONCILIATION",
        },
      ]);
      if (!inserted) continue;
      const delta = mismatch.dummyType === "BUY" ? mismatch.dummyUnits : `-${mismatch.dummyUnits}`;
      await positionRepo.adjustPosition(client, userId, accountAssetId, delta);
      dummiesCreated++;
    }

    await accountRepo.backfillIdentityIfMissing(
      client,
      accountId,
      payload.identity.brokerName,
      payload.identity.accountIdentifier
    );

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }

  await jobRepo.completeJob(pool, jobId, {
    total_extracted: payload.totalExtracted,
    total_inserted: toInsert.length + dummiesCreated,
    duplicates_skipped: payload.duplicatesSkipped + extraSkipped,
    reconciled_count: dummiesCreated,
  });

  return {
    totalInserted: toInsert.length,
    duplicatesSkipped: payload.duplicatesSkipped + extraSkipped,
    dummiesCreated,
  };
}

export async function rejectInvestmentsUpload(userId: bigint, jobId: string): Promise<void> {
  const job = await jobRepo.getJob(pool, jobId, userId);
  if (!job) throw new HttpError(404, "Job not found");
  if (job.status !== "AWAITING_CONFIRMATION") {
    throw new HttpError(409, `Job is not awaiting confirmation (status: ${job.status})`);
  }
  await jobRepo.rejectJob(pool, jobId);
}
