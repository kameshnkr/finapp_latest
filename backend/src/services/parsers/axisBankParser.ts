/**
 * Custom parser for Axis Bank PDF statement text pages.
 *
 * Format characteristics:
 *  - Each transaction row ends with:  AMOUNT  BALANCE  3DIGIT_BRANCH_CODE
 *  - New transaction always starts with a DD-MM-YYYY date (possibly on its own line)
 *  - CREDIT vs DEBIT is determined by comparing current balance to previous balance
 *  - OPENING BALANCE / CLOSING BALANCE appear on dedicated lines
 *
 * Returns the same LlmPageResult type used by the LLM path, so it is a
 * drop-in replacement with no changes needed downstream.
 */

import type { LlmPageResult, LlmTransaction } from "../statementProcessingService.js";

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

  // UPI: UPI/P2A|P2M/TXN_ID/PAYEE/CHANNEL/BANK — payee is at index 3
  if (/^UPI\//i.test(s)) {
    const parts = s.split("/");
    const payee = (parts[3] ?? "").replace(/_/g, " ").trim();
    if (payee) return toTitleCase(payee);
  }

  // NEFT: NEFT/REF/DESCRIPTION/BANK/REMARKS — description at index 2
  if (/^NEFT\//i.test(s)) {
    const parts = s.split("/");
    const desc = (parts[2] ?? "")
      .replace(/\b\d{4}[A-Z]{3}\b/g, "")  // strip "2026JAN" etc.
      .replace(/\b[A-Z0-9]{10,}\b/g, "")  // strip long alphanumeric refs
      .replace(/\s+/g, " ")
      .trim();
    if (desc) return toTitleCase(desc);
  }

  // ACH: ACH-DR-COMPANY NAME-ALPHANUMERIC_REF
  // Company name is between "ACH-DR-" and the "-" before the ref code
  const achMatch = /^ACH-(?:DR|CR)-(.+?)\s*-[A-Z0-9]/i.exec(s);
  if (achMatch) {
    return toTitleCase(achMatch[1].replace(/-/g, " ").trim());
  }

  // ECS charges
  if (/^ECS /i.test(s)) return "ECS Transaction Charges";

  // Fallback: title-case first 60 chars
  return toTitleCase(s.slice(0, 60));
}

// ── Lines to skip ─────────────────────────────────────────────────────────────

const SKIP_LINE_RE = new RegExp([
  "^(OPENING|CLOSING|TRANSACTION TOTAL)",
  "^(Legends|Unless|The closing|We would|With effect|Deposit|In compliance|To ensure)",
  "^(REGISTERED OFFICE|BRANCH ADDRESS)",
  "^(\\+\\+\\+\\+|--|Tran Date|Joint Holder|Nominee|Registered|Scheme|Currency|Statement of)",
  "^[A-Z]+-Transaction trough",
].join("|"), "i");

// ── Core parser ───────────────────────────────────────────────────────────────

// Trailing pattern every Axis Bank transaction ends with:
//   AMOUNT  BALANCE  BRANCH_INIT(3 digits)
const TAIL_RE   = /([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(\d{3})\s*$/;
const DATE_START = /^\d{2}-\d{2}-\d{4}/;
const DATE_PART  = /^(\d{2}-\d{2}-\d{4})\s*/;
const CHQ_PREFIX = /^\d{5,10}\s+/;  // optional cheque number after date

export function parseAxisBankPage(text: string): LlmPageResult {
  const lines = text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

  let opening_balance: number | null = null;
  let closing_balance: number | null = null;

  // ── Step 1: Extract opening / closing balances ────────────────────────────
  for (const line of lines) {
    const obMatch = /OPENING BALANCE\s+([\d,]+\.\d{2})/.exec(line);
    if (obMatch) opening_balance = parseFloat(obMatch[1].replace(/,/g, ""));

    const cbMatch = /CLOSING BALANCE\s+([\d,]+\.\d{2})/.exec(line);
    if (cbMatch) closing_balance = parseFloat(cbMatch[1].replace(/,/g, ""));
  }

  // ── Step 2: Join multi-line transaction records ───────────────────────────
  // A new record starts when a line begins with DD-MM-YYYY.
  // Continuation lines (no leading date) are appended to the current record.
  //
  // IMPORTANT: once "TRANSACTION TOTAL" is seen, we have left the transaction
  // section. All subsequent lines (legal boilerplate, branch address, etc.)
  // must NOT be appended to the last record — they would corrupt TAIL_RE and
  // silently drop the final transaction on the last page.
  const records: string[] = [];
  let footerReached = false;

  for (const line of lines) {
    if (/^TRANSACTION TOTAL/i.test(line)) {
      footerReached = true;
    }
    if (footerReached || SKIP_LINE_RE.test(line)) continue;

    if (DATE_START.test(line)) {
      records.push(line);
    } else if (records.length > 0) {
      records[records.length - 1] += " " + line;
    }
  }

  // ── Step 3: Parse each record ─────────────────────────────────────────────
  const transactions: LlmTransaction[] = [];
  let prevBalance: number | null = opening_balance;

  for (const record of records) {
    const tailMatch = TAIL_RE.exec(record);
    if (!tailMatch) continue;

    const amount  = parseFloat(tailMatch[1].replace(/,/g, ""));
    const balance = parseFloat(tailMatch[2].replace(/,/g, ""));

    const dateMatch = DATE_PART.exec(record);
    if (!dateMatch) continue;

    const [dd, mm, yyyy] = dateMatch[1].split("-");
    const isoDate = `${yyyy}-${mm}-${dd}`;

    // Everything between date and trailing numbers is the description
    const afterDate = record.slice(dateMatch[0].length, tailMatch.index).trim();
    const desc = afterDate.replace(CHQ_PREFIX, "").replace(/\s+/g, " ").trim();
    if (!desc) continue;

    // CREDIT if balance went up, DEBIT otherwise
    const type = (prevBalance !== null && balance > prevBalance) ? "CREDIT" : "DEBIT";
    prevBalance = balance;

    transactions.push({
      date:                       isoDate,
      description:                desc,
      description_human_readable: humanReadable(desc),
      amount,
      type,
    });
  }

  return { opening_balance, closing_balance, transactions };
}

// ── Detection heuristic ───────────────────────────────────────────────────────

/**
 * Returns true if the page text looks like an Axis Bank statement page.
 * Checks for Axis-specific markers so we don't run this parser on other banks.
 */
export function isAxisBankPage(text: string): boolean {
  return (
    /UTIB\d{7}/i.test(text) ||           // Axis Bank IFSC prefix
    /AXIS BANK/i.test(text) ||
    /915\d{9,}/i.test(text)              // Axis Bank account number pattern
  );
}
