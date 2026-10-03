/**
 * ONE-TIME BACKFILL — reclassifies any pre-existing reconciliation dummy
 * trades from source='STATEMENT' to source='RECONCILIATION'.
 *
 * Context: dummy trades were always inserted via the same insertTransactions
 * path as real broker trades, which hardcoded source='STATEMENT' until this
 * fix. There was no stored marker distinguishing them — only their
 * fingerprint was computed differently (computeReconciliationDummyFingerprint
 * vs computeInvestmentsFingerprint). This script re-derives that fingerprint
 * for every existing transaction from its currently-stored columns and
 * compares it to the stored `fingerprint` value: a match proves the row was
 * originally created as a reconciliation dummy, regardless of what `source`
 * says today.
 *
 * Safe to re-run any number of times (only ever flips STATEMENT/MANUAL rows
 * that verifiably match the dummy fingerprint formula to RECONCILIATION;
 * never touches rows already marked RECONCILIATION, never a false positive
 * since the fingerprint is a SHA-256 hash over accountId+accountAssetId+isin+
 * type+units+date).
 *
 * Usage:
 *   npx tsx src/scripts/backfillReconciliationTradeSource.ts
 */

import { pool } from "../db/pool.js";
import { computeReconciliationDummyFingerprint } from "../utils/investmentsFingerprint.js";

type Row = {
  id: string;
  account_asset_id: string;
  account_id: string;
  isin: string;
  transaction_type: "BUY" | "SELL";
  units: string;
  transaction_date: string;
  fingerprint: string | null;
};

async function main(): Promise<void> {
  const { rows } = await pool.query<Row>(
    `SELECT t.id::text, t.account_asset_id::text, aa.account_id::text, a.isin,
            t.transaction_type, t.units::text, t.transaction_date::text, t.fingerprint
     FROM investments_transactions t
     JOIN investments_account_assets aa ON aa.id = t.account_asset_id
     JOIN investments_assets a ON a.id = aa.asset_id
     WHERE t.source != 'RECONCILIATION' AND t.fingerprint IS NOT NULL`
  );

  console.log(`Scanning ${rows.length} non-RECONCILIATION transaction(s) with a fingerprint...`);

  const toFix: string[] = [];
  for (const row of rows) {
    const expected = computeReconciliationDummyFingerprint({
      accountId: BigInt(row.account_id),
      accountAssetId: BigInt(row.account_asset_id),
      isin: row.isin,
      transactionType: row.transaction_type,
      units: row.units,
      transactionDate: row.transaction_date,
    });
    if (expected === row.fingerprint) {
      toFix.push(row.id);
    }
  }

  if (toFix.length === 0) {
    console.log("No mismarked reconciliation dummy trades found — nothing to backfill.");
  } else {
    await pool.query(
      `UPDATE investments_transactions SET source = 'RECONCILIATION', version = version + 1, updated_at = now()
       WHERE id = ANY($1::bigint[])`,
      [toFix]
    );
    console.log(`Backfilled ${toFix.length} reconciliation dummy trade(s) to source='RECONCILIATION'.`);
  }

  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
