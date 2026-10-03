import * as XLSX from "xlsx";
import { env } from "../config/env.js";

export type ExcelSheetRows = {
  sheetName: string;
  /** Every non-empty row in the sheet, unsliced and in original order —
   * titles, client/account metadata, summary totals, column headers, and
   * actual data rows are all included as-is. We deliberately do NOT try to
   * deterministically decide which row is "the header" or which sheets are
   * redundant rollups: broker export layouts vary too much for a wording-
   * or position-based guess to be trustworthy (see investmentsUploadProcessingService.ts's
   * mergeHoldingsByIsin doc-comment for the concrete case this bit us on).
   * Instead, the LLM is given the whole sheet and told to use its own
   * judgment about what's a header/title vs. real data, guided by the one
   * rule we DO enforce mechanically downstream: a row with no discoverable
   * ISIN is never treated as a holding/trade. */
  rows: string[][];
};

function cellToString(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (typeof v === "number") return String(v);
  return String(v).trim();
}

function isRowEmpty(row: string[]): boolean {
  return row.every((c) => c.trim() === "");
}

/**
 * Reads every worksheet in the workbook (not just the first) and returns
 * each sheet's full set of non-empty rows, fully stringified. Fails fast if
 * any sheet exceeds the configured row-count safety cap.
 *
 * Deliberately does NOT skip any sheet (e.g. a "Combined"/"Consolidated"
 * rollup) and does NOT slice out leading title/metadata rows here — see
 * the ExcelSheetRows doc-comment above for why. Any duplicate holdings a
 * rollup sheet introduces are handled downstream by mergeHoldingsByIsin,
 * which reacts to the actual reported values rather than to sheet naming
 * conventions.
 */
export function readWorkbookAllSheets(buffer: Buffer): ExcelSheetRows[] {
  const workbook = XLSX.read(buffer, { type: "buffer", cellDates: true });
  const sheets: ExcelSheetRows[] = [];

  for (const sheetName of workbook.SheetNames) {
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) continue;

    const raw = XLSX.utils.sheet_to_json<unknown[]>(sheet, {
      header: 1,
      raw: true,
      defval: "",
    });

    const rows = raw.map((r) => r.map(cellToString)).filter((r) => !isRowEmpty(r));
    if (rows.length === 0) continue;

    if (rows.length > env.investmentsMaxExcelRows) {
      throw new Error(
        `Sheet "${sheetName}" has ${rows.length} rows, exceeding the maximum allowed ` +
          `${env.investmentsMaxExcelRows}. Please split the file by date range and re-upload.`
      );
    }

    sheets.push({ sheetName, rows });
  }

  return sheets;
}

export function chunkRows(rows: string[][], batchSize: number): string[][][] {
  const batches: string[][][] = [];
  for (let i = 0; i < rows.length; i += batchSize) {
    batches.push(rows.slice(i, i + batchSize));
  }
  return batches;
}

// Every LLM call for a sheet gets these leading rows prepended as context,
// regardless of which batch it's serving — real broker exports always put
// titles/metadata/column-headers near the very top of a sheet, so this is a
// safe structural assumption (not a wording guess) that lets later batches
// still see the column-header row even though we never identify it
// ourselves.
const LEADING_CONTEXT_ROW_COUNT = 30;

/** Renders a sheet's leading rows (as context) plus one batch of rows (to
 * actually extract from) as plain numbered text for the LLM prompt.
 * startIndex is the 1-based row number of the first row in `batch`, using
 * the same numbering as the context section, so the model can tell when a
 * row appears in both (and should only extract it once, from the "Rows to
 * extract" section). */
export function formatRowsForPrompt(
  allRows: string[][],
  batch: string[][],
  startIndex: number
): string {
  const leadingCount = Math.min(LEADING_CONTEXT_ROW_COUNT, allRows.length);
  const contextLines = allRows
    .slice(0, leadingCount)
    .map((r, i) => `Row ${i + 1}: ${r.join(" | ")}`);
  const batchLines = batch.map((r, i) => `Row ${startIndex + i}: ${r.join(" | ")}`);

  return [
    `Context — the first ${leadingCount} row(s) of this sheet (may include a title, ` +
      `client/account metadata, summary totals, and/or the column header row; shown only so ` +
      `you understand what each column means — do NOT extract data from this section):`,
    ...contextLines,
    ``,
    `Rows to extract data from (some of these may repeat rows already shown above as context — ` +
      `extract from THIS section only, so each real row is extracted exactly once):`,
    ...batchLines,
  ].join("\n");
}

/** Cheap textual snippet of a workbook used only for best-effort
 * broker/account-identifier extraction — not for trade data itself. Just
 * the first several rows of every sheet, since that's where "Client ID" /
 * "Folio No." / broker name text actually lives in real broker exports. */
export function buildIdentitySnippet(sheets: ExcelSheetRows[], maxRowsPerSheet = 12): string {
  return sheets
    .map((s) => `Sheet "${s.sheetName}":\n` + s.rows.slice(0, maxRowsPerSheet).map((r) => r.join(" | ")).join("\n"))
    .join("\n\n");
}
