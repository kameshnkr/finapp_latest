/**
 * TEST SCRIPT — Axis Bank statement custom parser
 *
 * Parses a single page of extracted text from an Axis Bank PDF statement
 * and returns output in the same compact array-of-arrays format as the LLM service:
 *   { ob, cb, t: [[date, description, description_human_readable, amount, type], ...] }
 *
 * CREDIT/DEBIT is determined by comparing running balance (prev → current).
 * No column-position guessing needed.
 *
 * Usage:
 *   npx tsx src/scripts/axisBankParserTest.ts <path/to/page.txt>
 *
 * Example:
 *   npx tsx src/scripts/axisBankParserTest.ts .logs/big_AcctStatement_XXX7918_12042026/page-1.txt
 */

import fs from "fs";
import path from "path";

// ── Output type (mirrors LLM compact format) ──────────────────────────────────

type PageResult = {
  ob: number | null;  // opening balance on this page
  cb: number | null;  // closing balance on this page
  t: string[][];      // [date, description, description_human_readable, amount, type]
};

// ── Human-readable description rules ─────────────────────────────────────────

function toTitleCase(s: string): string {
  return s
    .toLowerCase()
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .replace(/\s+/g, " ")
    .trim();
}

function humanReadable(raw: string): string {
  const s = raw.trim();

  // ── UPI: UPI/P2A|P2M/TXN_ID/PAYEE/CHANNEL/BANK ...
  //    payee is always at index 3 when split by "/"
  if (/^UPI\//i.test(s)) {
    const parts = s.split("/");
    const payee = (parts[3] ?? "").trim();
    if (payee) return toTitleCase(payee);
  }

  // ── NEFT: NEFT/REF/DESCRIPTION/BANK/REMARKS
  //    description is at index 2; strip year/month codes like "2026JAN" and numeric refs
  if (/^NEFT\//i.test(s)) {
    const parts = s.split("/");
    const desc = (parts[2] ?? "")
      .replace(/\b\d{4}[A-Z]{3}\b/g, "")   // strip "2026JAN" etc.
      .replace(/\b[A-Z0-9]{10,}\b/g, "")   // strip long reference codes
      .replace(/\s+/g, " ")
      .trim();
    if (desc) return toTitleCase(desc);
  }

  // ── ACH: ACH-DR-COMPANY NAME-ALPHANUMERIC_REF
  //    ref starts with a char that is NOT a space (company names have spaces, refs don't)
  //    e.g. "ACH-DR-INDIAN CLEARING CORP-0000KE9..." → "Indian Clearing Corp"
  //    e.g. "ACH-DR-ZERODHA BROKING LTD-75UA5Z..."  → "Zerodha Broking Ltd"
  const achMatch = /^ACH-(?:DR|CR)-(.+?)\s*-[A-Z0-9]/i.exec(s);
  if (achMatch) {
    return toTitleCase(achMatch[1].replace(/-/g, " ").trim());
  }

  // ── ECS charges
  if (/^ECS /i.test(s)) return "ECS Transaction Charges";

  // ── Fallback: title-case first 60 chars
  return toTitleCase(s.slice(0, 60));
}

// ── Core parser ───────────────────────────────────────────────────────────────

function parsePage(text: string): PageResult {
  const lines = text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  let ob: number | null = null;
  let cb: number | null = null;

  // ── Step 1: Extract opening / closing balances from special lines ──────────
  for (const line of lines) {
    const obMatch = /OPENING BALANCE\s+([\d,]+\.\d{2})/.exec(line);
    if (obMatch) ob = parseFloat(obMatch[1].replace(/,/g, ""));

    const cbMatch = /CLOSING BALANCE\s+([\d,]+\.\d{2})/.exec(line);
    if (cbMatch) cb = parseFloat(cbMatch[1].replace(/,/g, ""));
  }

  // ── Step 2: Join multi-line transaction records ────────────────────────────
  // A new record starts when a line begins with DD-MM-YYYY.
  // Continuation lines (no leading date) are appended to the current record.
  //
  // "TRANSACTION TOTAL" marks end of transaction section — everything after
  // it is legal boilerplate that must not be appended to the last record.
  const DATE_START_RE = /^\d{2}-\d{2}-\d{4}/;
  const records: string[] = [];
  let footerReached = false;

  for (const line of lines) {
    if (/^TRANSACTION TOTAL/i.test(line)) {
      footerReached = true;
    }
    if (footerReached) continue;

    // Skip known non-transaction header/footer lines
    if (
      /^(OPENING|CLOSING|Legends|Unless|The closing|We would|With effect|Deposit|In compliance|To ensure|REGISTERED|BRANCH ADDRESS|----|\+\+\+\+|--|Tran Date)/i.test(line) ||
      /^[A-Z]+-Transaction trough/.test(line) ||
      /^[A-Z]+-/.test(line) && !/^\d{2}-\d{2}-\d{4}/.test(line) && records.length === 0
    ) {
      continue;
    }

    if (DATE_START_RE.test(line)) {
      records.push(line);
    } else if (records.length > 0) {
      records[records.length - 1] += " " + line;
    }
  }

  // ── Step 3: Parse each record into a transaction ───────────────────────────
  //
  // Trailing pattern every transaction ends with:
  //   AMOUNT  BALANCE  BRANCH_INIT
  //   e.g. "12000.00 877287.67 030"
  //
  // CREDIT vs DEBIT is derived from balance direction:
  //   balance increased from previous → CREDIT
  //   balance decreased from previous → DEBIT
  //
  const TAIL_RE     = /([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(\d{3})\s*$/;
  const DATE_PART   = /^(\d{2}-\d{2}-\d{4})\s*/;
  // Optional cheque number: purely numeric, 5–10 digits, right after the date
  const CHQ_PREFIX  = /^\d{5,10}\s+/;

  const transactions: string[][] = [];
  let prevBalance: number | null = ob;

  for (const record of records) {
    const tailMatch = TAIL_RE.exec(record);
    if (!tailMatch) continue; // Not a transaction row (header, footer, etc.)

    const amount  = parseFloat(tailMatch[1].replace(/,/g, ""));
    const balance = parseFloat(tailMatch[2].replace(/,/g, ""));

    const dateMatch = DATE_PART.exec(record);
    if (!dateMatch) continue;

    const rawDate = dateMatch[1]; // "DD-MM-YYYY"
    const [dd, mm, yyyy] = rawDate.split("-");
    const isoDate = `${yyyy}-${mm}-${dd}`;

    // Everything between the date and the trailing numbers is the description
    const afterDate = record.slice(dateMatch[0].length, tailMatch.index).trim();
    // Strip leading cheque number if present
    const desc = afterDate.replace(CHQ_PREFIX, "").replace(/\s+/g, " ").trim();

    // Determine type from balance change
    const type = (prevBalance !== null && balance > prevBalance) ? "CREDIT" : "DEBIT";
    prevBalance = balance;

    transactions.push([
      isoDate,
      desc,
      humanReadable(desc),
      amount.toFixed(2),
      type,
    ]);
  }

  return { ob, cb, t: transactions };
}

// ── CLI entry point ───────────────────────────────────────────────────────────

const inputFile = process.argv[2];
if (!inputFile) {
  console.error("Usage: npx tsx src/scripts/axisBankParserTest.ts <page.txt>");
  process.exit(1);
}

const text = fs.readFileSync(path.resolve(inputFile), "utf-8");
const result = parsePage(text);

const pad = (s: string, n: number) => s.slice(0, n).padEnd(n);

console.log("\n── Summary ───────────────────────────────────────────────────────");
console.log(`  File            : ${path.basename(inputFile)}`);
console.log(`  Opening balance : ${result.ob ?? "not found on this page"}`);
console.log(`  Closing balance : ${result.cb ?? "not found on this page"}`);
console.log(`  Transactions    : ${result.t.length}`);

console.log("\n── Transactions ──────────────────────────────────────────────────");
console.log(
  `  ${"#".padStart(3)}  ${"Date".padEnd(12)}  ${"T".padEnd(6)}  ${"Amount".padStart(12)}  ${"Human Readable".padEnd(35)}  Raw Description`
);
console.log("  " + "─".repeat(120));
result.t.forEach(([date, desc, readable, amount, type], i) => {
  const sign = type === "CREDIT" ? "+" : "-";
  console.log(
    `  ${String(i + 1).padStart(3)}  ${date.padEnd(12)}  ${type.padEnd(6)}  ${(sign + amount).padStart(12)}  ${pad(readable, 35)}  ${desc.slice(0, 70)}`
  );
});

console.log("\n── Raw LLM-format JSON output ────────────────────────────────────");
const json = JSON.stringify({ ob: result.ob, cb: result.cb, t: result.t });
console.log(json.slice(0, 2000) + (json.length > 2000 ? "\n...(truncated)" : ""));
