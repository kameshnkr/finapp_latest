import { createHash } from "crypto";

/**
 * Deterministic dedup fingerprint for an investments trade.
 *
 * Relies ONLY on fields that are single, literal, directly-present columns
 * in every broker export this pipeline has been tested against: accountId,
 * isin, transaction type, units, price, date. Two rounds of live re-upload
 * testing against a real broker file eliminated other candidate fields:
 *   - transaction_time / trade_id / order_id: reference/ID columns that the
 *     LLM did NOT reliably re-extract identically across separate calls on
 *     the same source row (confirmed: some rows differed on a repeat call
 *     even at temperature 0), breaking dedup on re-upload of an unchanged
 *     file.
 *   - amount: the real broker Trade Book file tested against has NO
 *     amount/net-amount column at all — only Quantity and Price are
 *     present. The LLM was therefore *computing* amount ≈ units × price
 *     itself on each call (per the extraction prompt's "extract exactly
 *     what the statement shows" instruction, with nothing to extract), and
 *     that computed value varied by rounding noise between calls — e.g.
 *     7750.00 vs 7755.00 for the identical 174.267 × 44.4697 row. amount is
 *     still stored/validated (per the amount≈units×price sanity check) but
 *     excluded from the fingerprint since it is not a stable extraction
 *     target on files without a genuine amount column.
 * units, price, isin, and date, by contrast, were byte-identical across
 * every repeated test run — they are single literal source columns, not
 * LLM-computed values.
 *
 * Trade-off accepted: two genuinely distinct trades for the same asset,
 * type, units, and price on the same day (e.g. two identical SIP
 * installments) would collide and the second would be silently dropped as
 * a "duplicate". This mirrors the same trade-off Banking's own fingerprint
 * already makes (account + date + amount + description + direction, no
 * bank-assigned transaction ID) and is considered acceptable for this MVP.
 */
export type InvestmentsFingerprintInput = {
  accountId: bigint;
  isin: string;
  transactionType: "BUY" | "SELL";
  /** Fixed-precision string, e.g. units.toFixed(6) */
  units: string;
  /** Fixed-precision string, e.g. price.toFixed(4) */
  price: string;
  transactionDate: string;
};

export function computeInvestmentsFingerprint(input: InvestmentsFingerprintInput): string {
  const parts = [
    input.accountId.toString(),
    input.isin.trim().toUpperCase(),
    input.transactionType,
    input.units.trim(),
    input.price.trim(),
    input.transactionDate.trim(),
  ];
  return createHash("sha256").update(parts.join("|")).digest("hex");
}

/**
 * Fingerprint for a reconciliation dummy trade. Distinct namespace
 * ("RECONCILIATION" marker) so it can never collide with a real broker
 * trade, and deterministic across repeated confirm attempts on the same job
 * (safe to retry without double-inserting).
 */
export function computeReconciliationDummyFingerprint(input: {
  accountId: bigint;
  accountAssetId: bigint;
  isin: string;
  transactionType: "BUY" | "SELL";
  units: string;
  transactionDate: string;
}): string {
  const parts = [
    "RECONCILIATION",
    input.accountId.toString(),
    input.accountAssetId.toString(),
    input.isin.trim().toUpperCase(),
    input.transactionType,
    input.units.trim(),
    input.transactionDate.trim(),
  ];
  return createHash("sha256").update(parts.join("|")).digest("hex");
}
