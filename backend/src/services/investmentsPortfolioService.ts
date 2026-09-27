import { pool } from "../db/pool.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import * as assetRepo from "../repositories/investmentsAssetRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import { ensureDefaultInvestmentsDataForUser } from "./investmentsBootstrapService.js";

function n(s: string | null | undefined): number {
  if (s === null || s === undefined) return 0;
  const v = parseFloat(s);
  return Number.isFinite(v) ? v : 0;
}

function money(v: number): string {
  return v.toFixed(2);
}

/**
 * Total Portfolio Value = SUM(units x latest price) over every investment
 * position for the user. Positions whose asset has no synced price yet
 * contribute 0 (never null/undefined) — current value is always computed at
 * runtime, never stored.
 */
export async function getPotsOverview(userId: bigint): Promise<{
  totalPortfolioValue: string;
  pots: { id: string; name: string; description: string | null; currentValue: string }[];
}> {
  await ensureDefaultInvestmentsDataForUser(userId);

  const [pots, assetDetails, potPositions] = await Promise.all([
    potRepo.listActivePotsForUser(pool, userId),
    assetRepo.listAccountAssetDetailsForUser(pool, userId),
    positionRepo.listPotPositionDetailsForUser(pool, userId),
  ]);

  // account_asset_id -> latest price (0 if never synced)
  const priceByAccountAssetId = new Map<string, number>();
  let totalPortfolioValue = 0;
  for (const d of assetDetails) {
    const price = n(d.latest_price);
    priceByAccountAssetId.set(d.account_asset_id.toString(), price);
    totalPortfolioValue += n(d.units) * price;
  }

  // pot_id -> accumulated current value
  const potValueMap = new Map<string, number>();
  for (const pp of potPositions) {
    const price = priceByAccountAssetId.get(pp.account_asset_id.toString()) ?? 0;
    const key = pp.pot_id.toString();
    potValueMap.set(key, (potValueMap.get(key) ?? 0) + n(pp.units) * price);
  }

  return {
    totalPortfolioValue: money(totalPortfolioValue),
    pots: pots.map((p) => ({
      id: p.id.toString(),
      name: p.name,
      description: p.description,
      currentValue: money(potValueMap.get(p.id.toString()) ?? 0),
    })),
  };
}

export type AssetAllocationBreakdownEntry = {
  potId: string;
  potName: string;
  percentage: string;
  amount: string;
};

export type AssetEntry = {
  accountAssetId: string;
  assetId: string;
  isin: string;
  name: string;
  symbol: string | null;
  assetClass: string;
  units: string;
  latestPrice: string | null;
  priceDate: string | null;
  currentValue: string;
  potAllocations: AssetAllocationBreakdownEntry[];
};

export type AccountWithAssetsEntry = {
  accountId: string;
  accountName: string;
  brokerName: string | null;
  accountIdentifier: string | null;
  assets: AssetEntry[];
};

/**
 * Assets grouped by Investment Account, each asset carrying a read-only Pot
 * allocation breakdown that includes every active Pot (even zero-allocation
 * ones), matching the AssetsTab spec exactly. Percentages/amounts here are
 * always derived at runtime from investments_pot_positions x latest price —
 * never read from the per-transaction allocation_value column, which only
 * reflects the split at the time each individual trade was labeled.
 */
export async function getAssetsGroupedByAccount(userId: bigint): Promise<AccountWithAssetsEntry[]> {
  await ensureDefaultInvestmentsDataForUser(userId);

  const [accounts, assetDetails, potPositions, pots] = await Promise.all([
    accountRepo.listActiveAccountsForUser(pool, userId),
    assetRepo.listAccountAssetDetailsForUser(pool, userId),
    positionRepo.listPotPositionDetailsForUser(pool, userId),
    potRepo.listActivePotsForUser(pool, userId),
  ]);

  // "account_asset_id|pot_id" -> units, for O(1) lookups while building the breakdown.
  const potUnitsByKey = new Map<string, number>();
  for (const pp of potPositions) {
    potUnitsByKey.set(`${pp.account_asset_id}|${pp.pot_id}`, n(pp.units));
  }

  const assetsByAccountId = new Map<string, AssetEntry[]>();
  for (const d of assetDetails) {
    const units = n(d.units);
    const price = n(d.latest_price);
    const currentValue = units * price;

    const potAllocations: AssetAllocationBreakdownEntry[] = pots.map((pot) => {
      const potUnits = potUnitsByKey.get(`${d.account_asset_id}|${pot.id}`) ?? 0;
      const percentage = units > 0 ? (potUnits / units) * 100 : 0;
      const amount = potUnits * price;
      return {
        potId: pot.id.toString(),
        potName: pot.name,
        percentage: percentage.toFixed(2),
        amount: money(amount),
      };
    });

    const entry: AssetEntry = {
      accountAssetId: d.account_asset_id.toString(),
      assetId: d.asset_id.toString(),
      isin: d.isin,
      name: d.asset_name,
      symbol: d.symbol,
      assetClass: d.asset_class,
      units: d.units,
      latestPrice: d.latest_price,
      priceDate: d.price_date,
      currentValue: money(currentValue),
      potAllocations,
    };

    const key = d.account_id.toString();
    const list = assetsByAccountId.get(key) ?? [];
    list.push(entry);
    assetsByAccountId.set(key, list);
  }

  return accounts.map((a) => ({
    accountId: a.id.toString(),
    accountName: a.name,
    brokerName: a.broker_name,
    accountIdentifier: a.account_identifier,
    assets: assetsByAccountId.get(a.id.toString()) ?? [],
  }));
}
