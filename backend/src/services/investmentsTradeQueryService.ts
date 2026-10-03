import { pool } from "../db/pool.js";
import * as txRepo from "../repositories/investmentsTransactionRepository.js";
import * as allocationRepo from "../repositories/investmentsAllocationRepository.js";
import type { InvestmentsAllocationStatus } from "../types/investmentsDomain.js";
import { HttpError } from "../utils/errors.js";

export type TradesPageResult = {
  trades: ReturnType<typeof serializeTrade>[];
  nextCursor: string | null;
  hasMore: boolean;
};

export async function listTradesPaged(
  userId: bigint,
  allocationStatus: InvestmentsAllocationStatus,
  params: { limit: number; cursor?: string }
): Promise<TradesPageResult> {
  let cursorDate: string | undefined;
  let cursorId: bigint | undefined;

  if (params.cursor) {
    try {
      const decoded = JSON.parse(
        Buffer.from(params.cursor, "base64url").toString("utf8")
      ) as { d: string; id: string };
      if (!/^\d{4}-\d{2}-\d{2}$/.test(decoded.d)) throw new Error("bad date");
      cursorDate = decoded.d;
      cursorId = BigInt(decoded.id);
    } catch {
      throw new HttpError(400, "Invalid cursor");
    }
  }

  const result = await txRepo.listTradesPaged(pool, {
    userId,
    allocationStatus,
    limit: params.limit,
    cursorDate,
    cursorId,
  });

  let nextCursor: string | null = null;
  if (result.hasMore && result.rows.length > 0) {
    const oldest = result.rows[result.rows.length - 1]!;
    nextCursor = Buffer.from(
      JSON.stringify({ d: oldest.transaction_date, id: oldest.id.toString() })
    ).toString("base64url");
  }

  // Labeled trades also carry their Pot allocation breakdown.
  let breakdownByTxId = new Map<string, ReturnType<typeof serializeBreakdown>[]>();
  if (allocationStatus === "ALLOCATED" && result.rows.length > 0) {
    const breakdownRows = await allocationRepo.listAllocationsForTransactions(
      pool,
      result.rows.map((r) => r.id)
    );
    breakdownByTxId = new Map();
    for (const b of breakdownRows) {
      const key = b.transaction_id.toString();
      const list = breakdownByTxId.get(key) ?? [];
      list.push(serializeBreakdown(b));
      breakdownByTxId.set(key, list);
    }
  }

  return {
    trades: result.rows.map((r) => serializeTrade(r, breakdownByTxId.get(r.id.toString()) ?? [])),
    nextCursor,
    hasMore: result.hasMore,
  };
}

function serializeBreakdown(row: import("../repositories/investmentsAllocationRepository.js").AllocationBreakdownRow) {
  return {
    potId: row.pot_id.toString(),
    potName: row.pot_name,
    percentage: row.allocation_value,
    allocatedUnits: row.allocated_units,
  };
}

function serializeTrade(
  row: import("../repositories/investmentsTransactionRepository.js").InvestmentsTradeListRow,
  potAllocations: ReturnType<typeof serializeBreakdown>[]
) {
  return {
    id: row.id.toString(),
    accountId: row.account_id.toString(),
    accountName: row.account_name,
    accountAssetId: row.account_asset_id.toString(),
    isin: row.isin,
    assetName: row.asset_name,
    symbol: row.symbol,
    assetClass: row.asset_class,
    transactionType: row.transaction_type,
    units: row.units,
    price: row.price,
    amount: row.amount,
    transactionDate: row.transaction_date,
    source: row.source,
    sourceReferenceId: row.source_reference_id,
    allocationStatus: row.allocation_status,
    potAllocations,
    version: row.version,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}
