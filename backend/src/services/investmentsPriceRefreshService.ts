import { pool } from "../db/pool.js";
import { env } from "../config/env.js";
import * as priceRepo from "../repositories/investmentsPriceRepository.js";
import { HttpError } from "../utils/errors.js";

const PRICE_SOURCE = "TIGZIG_MF_NAV";

// Simple per-user in-flight guard — a deliberate simplification instead of a
// full job/polling table, since each refresh is one short synchronous call
// over a small ISIN set. In-memory is fine for this single-process backend;
// if the backend is ever scaled to multiple processes, this would need to
// move to a DB-backed lock (e.g. a short-lived row) instead.
const refreshInFlight = new Set<string>();

type TigzigSchemeEntry = {
  scheme_code: number;
  scheme_name: string;
  isin: string | null;
  isin2: string | null;
  data: { date: string; nav: number }[];
};

type TigzigNavResponse = {
  count: number;
  schemes: TigzigSchemeEntry[];
  not_found: string[];
};

async function fetchNavBatch(isins: string[]): Promise<TigzigNavResponse> {
  const url = `${env.investmentsTigzigNavUrl}?scheme=${encodeURIComponent(isins.join(","))}&latest=true`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.investmentsPriceRefreshTimeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal });
    const json = (await res.json().catch(() => null)) as unknown;

    if (!res.ok) {
      // The API uses a DIFFERENT error shape for a single-ISIN query that
      // isn't found: HTTP 404 + {code: "NOT_FOUND", ...}, rather than the
      // HTTP 200 + not_found[] array used for multi-ISIN queries. Batches
      // legitimately shrink to size 1 (e.g. only one stale asset left after
      // the same-day skip filter, or a user with a single holding) — treat
      // this specific case as a normal "not found" result, not a failure.
      if (
        res.status === 404 &&
        isins.length === 1 &&
        json !== null &&
        typeof json === "object" &&
        (json as { code?: string }).code === "NOT_FOUND"
      ) {
        return { count: 0, schemes: [], not_found: [isins[0]] };
      }
      throw new Error(`tigzig NAV API returned HTTP ${res.status}`);
    }

    if (json === null || typeof json !== "object") {
      throw new Error("tigzig NAV API returned an unexpected response shape");
    }

    // Multi-ISIN queries return {count, schemes: [...], not_found: [...]}.
    if (Array.isArray((json as TigzigNavResponse).schemes)) {
      const parsed = json as TigzigNavResponse;
      return {
        count: parsed.count ?? parsed.schemes.length,
        schemes: parsed.schemes,
        not_found: Array.isArray(parsed.not_found) ? parsed.not_found : [],
      };
    }

    // A single-ISIN query that IS found returns the scheme object directly
    // (no "schemes" wrapper) — normalize it into the same shape.
    const single = json as TigzigSchemeEntry;
    if (typeof single.scheme_code === "number" && Array.isArray(single.data)) {
      return { count: 1, schemes: [single], not_found: [] };
    }

    throw new Error("tigzig NAV API returned an unexpected response shape");
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") {
      throw new Error("tigzig NAV API request timed out");
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export type PriceRefreshResult = {
  eligibleCount: number;
  updatedCount: number;
  notFoundIsins: string[];
  // Assets excluded from this call entirely because their stored price is
  // already dated today (from any user's earlier refresh) — no external
  // API call was made for these.
  alreadyCurrentCount: number;
};

/**
 * Manual, user-triggered price refresh for this user's Mutual Fund/ETF
 * holdings (matched by ISIN via the tigzig NAV API). Stocks/OTHER assets
 * are never touched — the API is MF-NAV-specific.
 *
 * Prices are asset-level, not per-user (see investmentsPriceRepository.ts).
 * If ANY user already SYNCED a given asset earlier today (synced_at, not
 * price_date — NAV dates routinely lag over weekends/holidays, so a fresh
 * sync can legitimately return the same price_date as before), that asset
 * is skipped entirely (no external API call) rather than re-checked. This
 * is a same-day check only: a sync from yesterday or earlier is always
 * treated as stale and re-fetched.
 *
 * All external calls happen BEFORE any DB write, and every write happens in
 * one transaction — so a failed/partial external call, or any single write
 * failure, leaves investments_asset_latest_prices/investments_asset_price_history
 * completely unchanged (no partial updates). Current values and Pot values
 * are never stored, so there's nothing else to "recalculate" — they're
 * derived at read time from whatever these two tables hold.
 */
export async function refreshPricesForUser(userId: bigint): Promise<PriceRefreshResult> {
  const key = userId.toString();
  if (refreshInFlight.has(key)) {
    throw new HttpError(409, "A price refresh is already in progress for your account. Please wait for it to finish.");
  }
  refreshInFlight.add(key);

  try {
    const assets = await priceRepo.listRefreshableAssetsForUser(pool, userId);
    if (assets.length === 0) {
      return { eligibleCount: 0, updatedCount: 0, notFoundIsins: [], alreadyCurrentCount: 0 };
    }

    // Skip assets whose stored price is already dated today — from ANY
    // user's earlier refresh, since prices are asset-level, not per-user.
    const staleAssets = assets.filter((a) => !a.is_current_today);
    const alreadyCurrentCount = assets.length - staleAssets.length;

    if (staleAssets.length === 0) {
      return { eligibleCount: assets.length, updatedCount: 0, notFoundIsins: [], alreadyCurrentCount };
    }

    // isin/isin2 -> asset, so a response entry can be matched either way.
    const assetByIsin = new Map<string, priceRepo.RefreshableAssetRow>();
    for (const a of staleAssets) {
      assetByIsin.set(a.isin.toUpperCase(), a);
    }

    const isins = staleAssets.map((a) => a.isin);
    const batches = chunk(isins, env.investmentsPriceRefreshBatchSize);

    // ── Fetch ALL batches first — no DB write happens until every external
    // call has succeeded, so a failure partway through touches nothing. ──
    const allSchemes: TigzigSchemeEntry[] = [];
    const allNotFound: string[] = [];
    for (const batch of batches) {
      const result = await fetchNavBatch(batch);
      allSchemes.push(...result.schemes);
      allNotFound.push(...result.not_found);
    }

    // Match each returned scheme to one of our assets, by isin then isin2.
    const matched: { assetId: bigint; price: string; priceDate: string }[] = [];
    const matchedIsins = new Set<string>();
    for (const scheme of allSchemes) {
      const latest = scheme.data?.[0];
      if (!latest || !Number.isFinite(latest.nav)) continue;

      const byIsin = scheme.isin ? assetByIsin.get(scheme.isin.toUpperCase()) : undefined;
      const byIsin2 = !byIsin && scheme.isin2 ? assetByIsin.get(scheme.isin2.toUpperCase()) : undefined;
      const asset = byIsin ?? byIsin2;
      if (!asset) continue; // response entry doesn't correspond to any asset we asked about

      matched.push({
        assetId: asset.asset_id,
        price: latest.nav.toString(),
        priceDate: latest.date,
      });
      matchedIsins.add(asset.isin.toUpperCase());
    }

    // Anything we requested but that came back neither matched nor in the
    // API's own not_found list is still effectively "not found" from our
    // perspective — surface it the same way rather than silently dropping it.
    const notFoundIsins = Array.from(
      new Set([...allNotFound, ...isins.filter((isin) => !matchedIsins.has(isin.toUpperCase()))])
    );

    if (matched.length === 0) {
      return { eligibleCount: assets.length, updatedCount: 0, notFoundIsins, alreadyCurrentCount };
    }

    // ── Single transaction for every write ──
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      for (const m of matched) {
        await priceRepo.upsertLatestPrice(client, m.assetId, m.price, m.priceDate, PRICE_SOURCE);
        await priceRepo.insertPriceHistory(client, m.assetId, m.price, m.priceDate, PRICE_SOURCE);
      }
      await client.query("COMMIT");
    } catch (e) {
      await client.query("ROLLBACK");
      throw e;
    } finally {
      client.release();
    }

    return { eligibleCount: assets.length, updatedCount: matched.length, notFoundIsins, alreadyCurrentCount };
  } finally {
    refreshInFlight.delete(key);
  }
}
