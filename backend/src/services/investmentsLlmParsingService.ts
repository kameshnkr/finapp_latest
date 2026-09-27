import { callLlm } from "./llmService.js";
import { readWorkbookAllSheets, chunkRows, formatRowsForPrompt } from "./investmentsExcelService.js";
import { env } from "../config/env.js";
import type { InvestmentsAssetClass, InvestmentsTransactionType } from "../types/investmentsDomain.js";

// ── Parsed row types (pre-validation, pre-DB-resolution) ─────────────────────

export type RawHoldingEntry = {
  isin: string;
  name: string;
  symbol: string | null;
  assetClass: InvestmentsAssetClass;
  units: number;
  price: number | null;
  priceDate: string | null;
};

export type RawTradeEntry = {
  isin: string;
  name: string;
  symbol: string | null;
  assetClass: InvestmentsAssetClass;
  transactionType: InvestmentsTransactionType;
  units: number;
  price: number;
  amount: number;
  transactionDate: string; // YYYY-MM-DD
  transactionTime: string | null;
  tradeId: string | null;
  orderId: string | null;
};

export type BatchValidationResult = { valid: boolean; failures: string[] };

// ── Shared helpers ────────────────────────────────────────────────────────────

function stripJsonFences(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) return fenced[1].trim();
  return text.trim();
}

function parseJsonArray(raw: string, label: string): Record<string, unknown>[] {
  const cleaned = stripJsonFences(raw);
  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    throw new Error(`[${label}] LLM did not return valid JSON: ${raw.slice(0, 300)}`);
  }
  if (!Array.isArray(parsed)) {
    throw new Error(`[${label}] LLM output is not a JSON array`);
  }
  return parsed as Record<string, unknown>[];
}

function normalizeAssetClass(v: unknown): InvestmentsAssetClass {
  const s = String(v ?? "").trim().toUpperCase();
  if (s === "MUTUAL_FUND" || s === "STOCK" || s === "ETF") return s;
  return "OTHER";
}

function toNumberOrNull(v: unknown): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : parseFloat(String(v).replace(/[,₹\s]/g, ""));
  return Number.isFinite(n) ? n : null;
}

function toNumber(v: unknown): number {
  return toNumberOrNull(v) ?? NaN;
}

function toStringOrNull(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
}

// ── Holdings parsing ──────────────────────────────────────────────────────────

const HOLDINGS_SCHEMA_INSTRUCTIONS = `Return ONLY a single-line valid JSON array. No markdown, no code fences, no explanation, no newlines anywhere in the output.
Each element must have exactly these fields:
{"isin":"<string>","name":"<string>","symbol":<string or null>,"asset_class":"MUTUAL_FUND"|"STOCK"|"ETF"|"OTHER","units":<number>,"price":<number or null>,"price_date":"YYYY-MM-DD" or null}

Rules:
- isin: the ISIN code identifying the asset. If a row has no discoverable ISIN, OMIT that row entirely from the output — never invent one.
- units: the current quantity/units held, as a plain number (strip commas, currency symbols, unit suffixes).
- price: the latest NAV/price shown for this holding in this statement, if present; null otherwise.
- asset_class: MUTUAL_FUND for mutual fund schemes, STOCK for listed equity shares, ETF for exchange-traded funds, OTHER if unclear.
- Skip subtotal/total/section-header/blank/metadata rows, and rows that just restate a title/date/summary figure — they are not holdings.
- If the same holding (same ISIN, same units) appears more than once in the rows shown to you (e.g. a sheet that rolls up/duplicates rows also shown elsewhere), still include it — do not attempt to deduplicate yourself; that is handled downstream from the values you extract.
- Preserve row order from the input.`;

function buildHoldingsPrompt(allRows: string[][], batch: string[][], startIndex: number): string {
  return `You are a broker holdings-statement parser. The rows below come from a spreadsheet "holdings" (current portfolio) sheet. Column layout, headers, and any leading title/metadata rows vary by broker — infer column meaning generically from context; do not assume a fixed column order or that any particular row is a clean header.

${HOLDINGS_SCHEMA_INSTRUCTIONS}

${formatRowsForPrompt(allRows, batch, startIndex)}`;
}

export async function parseHoldingsFile(buffer: Buffer, jobId: string): Promise<RawHoldingEntry[]> {
  const sheets = readWorkbookAllSheets(buffer);
  const results: RawHoldingEntry[] = [];

  for (const sheet of sheets) {
    const batches = chunkRows(sheet.rows, env.investmentsExcelRowBatchSize);
    let rowOffset = 1;
    for (const batch of batches) {
      const label = `job:${jobId}/holdings/${sheet.sheetName}/rows:${rowOffset}-${rowOffset + batch.length - 1}`;
      const prompt = buildHoldingsPrompt(sheet.rows, batch, rowOffset);
      const raw = await callLlm(prompt, label);
      const parsedRows = parseJsonArray(raw, label);

      for (const row of parsedRows) {
        const isin = toStringOrNull(row["isin"])?.toUpperCase();
        if (!isin) continue;
        const units = toNumber(row["units"]);
        if (!Number.isFinite(units)) continue;
        results.push({
          isin,
          name: toStringOrNull(row["name"]) ?? isin,
          symbol: toStringOrNull(row["symbol"]),
          assetClass: normalizeAssetClass(row["asset_class"]),
          units,
          price: toNumberOrNull(row["price"]),
          priceDate: toStringOrNull(row["price_date"]),
        });
      }
      rowOffset += batch.length;
    }
  }

  return results;
}

// ── Trade Book parsing ────────────────────────────────────────────────────────

const TRADES_SCHEMA_INSTRUCTIONS = `Return ONLY a single-line valid JSON array. No markdown, no code fences, no explanation, no newlines anywhere in the output.
Each element must have exactly these fields:
{"isin":"<string>","name":"<string>","symbol":<string or null>,"asset_class":"MUTUAL_FUND"|"STOCK"|"ETF"|"OTHER","transaction_type":"BUY"|"SELL","units":<number>,"price":<number>,"amount":<number>,"transaction_date":"YYYY-MM-DD","transaction_time":"HH:MM:SS" or null,"trade_id":<string or null>,"order_id":<string or null>}

Rules:
- isin: the ISIN code identifying the traded asset. If a row has no discoverable ISIN (e.g. it is a charge/tax/fee ledger line, not an actual trade), OMIT that row entirely — never invent one.
- transaction_type: exactly "BUY" or "SELL" — infer from buy/sell/purchase/redeem/credit/debit-style columns as appropriate for a trade book.
- units, price, amount: plain numbers (strip commas/currency symbols). amount should approximately equal units x price (brokerage/charges may cause small differences) — extract exactly what the statement shows, do not compute it yourself.
- transaction_date: prefer the trade EXECUTION date if a separate execution timestamp column exists; otherwise use the trade date column. Format YYYY-MM-DD.
- transaction_time: the execution time if available (HH:MM:SS, 24-hour), else null.
- trade_id / order_id: broker-provided trade or order reference IDs if present as separate columns, else null. Do not confuse with ISIN, folio, or account numbers.
- Skip subtotal/total/section-header/blank/metadata rows, and rows that just restate a title/date/summary figure.
- Preserve row order from the input.`;

function buildTradesPrompt(allRows: string[][], batch: string[][], startIndex: number): string {
  return `You are a broker trade-book (transaction history) parser. The rows below come from a spreadsheet trade book listing individual buy/sell trades. Column layout, headers, and any leading title/metadata rows vary by broker — infer column meaning generically from context; do not assume a fixed column order or that any particular row is a clean header.

${TRADES_SCHEMA_INSTRUCTIONS}

${formatRowsForPrompt(allRows, batch, startIndex)}`;
}

function toTradeEntries(parsedRows: Record<string, unknown>[]): RawTradeEntry[] {
  return parsedRows
    .map((row): RawTradeEntry | null => {
      const isin = toStringOrNull(row["isin"])?.toUpperCase();
      if (!isin) return null;
      const transactionType = toStringOrNull(row["transaction_type"])?.toUpperCase();
      if (transactionType !== "BUY" && transactionType !== "SELL") return null;
      const units = toNumber(row["units"]);
      const price = toNumber(row["price"]);
      const amount = toNumber(row["amount"]);
      const transactionDate = toStringOrNull(row["transaction_date"]) ?? "";
      if (
        !Number.isFinite(units) ||
        !Number.isFinite(price) ||
        !Number.isFinite(amount) ||
        !/^\d{4}-\d{2}-\d{2}$/.test(transactionDate)
      ) {
        return null;
      }
      return {
        isin,
        name: toStringOrNull(row["name"]) ?? isin,
        symbol: toStringOrNull(row["symbol"]),
        assetClass: normalizeAssetClass(row["asset_class"]),
        transactionType,
        units,
        price,
        amount,
        transactionDate,
        transactionTime: toStringOrNull(row["transaction_time"]),
        tradeId: toStringOrNull(row["trade_id"]),
        orderId: toStringOrNull(row["order_id"]),
      };
    })
    .filter((e): e is RawTradeEntry => e !== null);
}

/**
 * Parses the Trade Book, batch by batch. Each batch is validated via the
 * injected `validateBatch` callback (kept as a parameter rather than a direct
 * import of investmentsValidationService to avoid a circular dependency —
 * the orchestrator wires the two together).
 *
 * On a failing batch: retries that SAME batch's LLM call exactly once. If it
 * still fails validation, the batch is recorded in `failedBatches` and its
 * rows are excluded — the caller (orchestrator) fails the whole job rather
 * than silently accepting a partially-validated file.
 */
export async function parseTradeBookFile(
  buffer: Buffer,
  jobId: string,
  validateBatch: (entries: RawTradeEntry[]) => BatchValidationResult
): Promise<{ entries: RawTradeEntry[]; failedBatches: { label: string; failures: string[] }[] }> {
  const sheets = readWorkbookAllSheets(buffer);
  const allEntries: RawTradeEntry[] = [];
  const failedBatches: { label: string; failures: string[] }[] = [];

  for (const sheet of sheets) {
    const batches = chunkRows(sheet.rows, env.investmentsExcelRowBatchSize);
    let rowOffset = 1;

    for (const batch of batches) {
      const label = `job:${jobId}/tradebook/${sheet.sheetName}/rows:${rowOffset}-${rowOffset + batch.length - 1}`;

      const attempt = async (): Promise<RawTradeEntry[]> => {
        const prompt = buildTradesPrompt(sheet.rows, batch, rowOffset);
        const raw = await callLlm(prompt, label);
        return toTradeEntries(parseJsonArray(raw, label));
      };

      let entries = await attempt();
      let check = validateBatch(entries);

      if (!check.valid) {
        console.warn(
          `[investments][${label}] amount sanity check failed — retrying this batch once. ` +
            `Failures: ${check.failures.join("; ")}`
        );
        entries = await attempt();
        check = validateBatch(entries);
      }

      // Always advance rowOffset regardless of outcome, so subsequent batch
      // labels stay accurate.
      rowOffset += batch.length;

      if (!check.valid) {
        failedBatches.push({ label, failures: check.failures });
        continue;
      }

      allEntries.push(...entries);
    }
  }

  return { entries: allEntries, failedBatches };
}

// ── Best-effort broker / account-identifier extraction (single call, cheap) ──

export type IdentityExtractionResult = {
  brokerName: string | null;
  accountIdentifier: string | null;
};

export async function extractAccountIdentity(
  snippet: string,
  jobId: string
): Promise<IdentityExtractionResult> {
  const prompt = `You are given a short snippet from a broker holdings/trade-book export. Identify:
1. The broker or AMC (asset management company) name, if mentioned anywhere.
2. The account/folio/client/DP identifier (a code or number identifying the specific investment account), if mentioned anywhere.

Return ONLY a single-line valid JSON object, no markdown, no explanation:
{"broker_name": <string or null>, "account_identifier": <string or null>}

If either is not confidently discoverable, use null — never guess.

Snippet:
---
${snippet.slice(0, 4000)}
---`;

  try {
    const raw = await callLlm(prompt, `job:${jobId}/identity`);
    const cleaned = stripJsonFences(raw);
    const parsed = JSON.parse(cleaned) as Record<string, unknown>;
    return {
      brokerName: toStringOrNull(parsed["broker_name"]),
      accountIdentifier: toStringOrNull(parsed["account_identifier"]),
    };
  } catch (e) {
    console.warn(`[investments][job:${jobId}/identity] extraction failed, skipping backfill: ${e}`);
    return { brokerName: null, accountIdentifier: null };
  }
}
