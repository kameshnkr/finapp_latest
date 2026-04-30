import { createHash } from "crypto";
import fs from "fs";
import { unlinkSync } from "fs";
import { PDFDocument } from "pdf-lib";
import { PDFParse } from "pdf-parse";
import { pool } from "../db/pool.js";
import { env } from "../config/env.js";
import * as jobRepo from "../repositories/statementJobRepository.js";
import * as txRepo from "../repositories/transactionRepository.js";
import type { StatementDraftItem } from "../repositories/transactionRepository.js";
import type { Direction } from "../types/domain.js";
import { callLlm, ACTIVE_PROVIDER } from "./llmService.js";
import { parseAxisBankPage, isAxisBankPage } from "./parsers/axisBankParser.js";

// ── Per-page extraction prompt ────────────────────────────────────────────────

function buildPagePrompt(pageNum: number, totalPages: number, pageText: string): string {
  return `You are a bank statement parser. Extract all transactions from page ${pageNum} of ${totalPages} of a bank statement.

The text below was extracted from a PDF page. Column headers may be absent on this page — they sometimes only appear on the first page. Infer the structure (date, description, amount, debit/credit) from the data patterns.

Return ONLY a single-line valid JSON object. No markdown, no code blocks, no explanation, no newlines anywhere in the output.

Exact format:
{"ob":<number or null>,"cb":<number or null>,"t":[["date","description","description_human_readable","amount","type"]]}

Field definitions:
- ob: opening / brought-forward balance on this page as a number, or null if not shown
- cb: closing / carried-forward balance on this page as a number, or null if not shown
- t: array of transactions — each transaction is an inner array with exactly 5 elements in this fixed order:
  [0] date              — YYYY-MM-DD string
  [1] description       — raw description copied exactly as it appears in the statement
  [2] description_human_readable — clean, user-friendly payee/merchant name (see rules below)
  [3] amount            — positive number as a string, e.g. "450.00"
  [4] type              — exactly "CREDIT" or "DEBIT"

Rules:
- CRITICAL: output must be a single line. Do NOT include any newline characters (\\n) anywhere.
- CRITICAL: every inner transaction array must have exactly 5 elements. Never omit an element; use "" for unknown values.
- amount must always be positive
- type must be exactly "CREDIT" or "DEBIT" — no other values
- date must be YYYY-MM-DD format
- description: copy the raw text exactly as it appears on the statement
- description_human_readable: strip UPI transaction IDs, reference numbers, bank routing codes and numeric noise; keep only the meaningful payee name or transaction purpose the user can recognise.
  Examples:
    "upi/p2m/646765141499/meridian restaurant/upi/hdfc bank ltd" → "Meridian Restaurant"
    "NEFT/00394857283/RAMESH KUMAR SHARMA" → "Ramesh Kumar Sharma"
    "ATM WITHDRAWAL 00123 SECTOR 14 GURGAON" → "ATM Withdrawal - Sector 14 Gurgaon"
    "ACH CREDIT SALARY ACME CORP LTD" → "Salary - Acme Corp"
- Preserve transaction order exactly as they appear top-to-bottom on this page
- Include ALL transactions; do not skip any
- If no transactions exist on this page use an empty array: {"ob":null,"cb":null,"t":[]}

Page text:
---
${pageText}
---`;
}

// ── LLM types (exported so parsers can reuse them) ────────────────────────────

export type LlmTransaction = {
  date: string;
  description: string;
  description_human_readable?: string;
  amount: number;
  type: string;
};

export type LlmPageResult = {
  opening_balance: number | null;
  closing_balance: number | null;
  transactions: LlmTransaction[];
};

// ── Normalization helpers ─────────────────────────────────────────────────────

function normalizeDescription(raw: string): string {
  return raw.toLowerCase().replace(/\s+/g, " ").trim();
}

function normalizeAmount(raw: number): string {
  return Math.abs(raw).toFixed(2);
}

function normalizeDate(raw: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (!match) throw new Error(`Invalid date format from LLM: ${raw}`);
  const d = new Date(`${raw}T00:00:00Z`);
  if (isNaN(d.getTime())) throw new Error(`Invalid date value: ${raw}`);
  return raw;
}

export function computeFingerprint(
  accountId: bigint,
  date: string,
  amount: string,
  description: string,
  type: "CREDIT" | "DEBIT"
): string {
  // Normalize every field before hashing so minor whitespace/case differences
  // in LLM output (e.g. "sri vegetables " vs "sri vegetables") don't produce
  // different fingerprints for the same real transaction.
  const normDate = date.trim();
  const normAmount = amount.trim();
  const normDesc = description.toLowerCase().replace(/\s+/g, "").trim();
  const normType = type.trim().toUpperCase();
  const raw = `${accountId}|${normDate}|${normAmount}|${normDesc}|${normType}`;
  return createHash("sha256").update(raw).digest("hex");
}

function stripJsonFences(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) return fenced[1].trim();
  return text.trim();
}

/** Parse the compact array-of-arrays JSON string returned by the LLM. */
function parseLlmRawOutput(raw: string, pageNum: number, jobId: string): LlmPageResult {
  console.log(
    `[statement][job:${jobId}] Page ${pageNum} [${ACTIVE_PROVIDER}] raw (${raw.length} chars):\n` +
      raw.slice(0, 2000) +
      (raw.length > 2000 ? `\n...(truncated)` : "")
  );
  const cleaned = stripJsonFences(raw);
  try {
    const parsed = JSON.parse(cleaned) as {
      ob?: number | null;
      cb?: number | null;
      t?: unknown[][];
    };
    const opening_balance = typeof parsed.ob === "number" ? parsed.ob : null;
    const closing_balance = typeof parsed.cb === "number" ? parsed.cb : null;
    const rows = Array.isArray(parsed.t) ? parsed.t : [];
    const transactions: LlmTransaction[] = rows
      .filter((row) => Array.isArray(row) && row.length >= 5)
      .map((row) => ({
        date:                       String(row[0] ?? "").trim(),
        description:                String(row[1] ?? "").trim(),
        description_human_readable: String(row[2] ?? "").trim() || undefined,
        amount:                     parseFloat(String(row[3] ?? "0")) || 0,
        type:                       String(row[4] ?? "").trim().toUpperCase(),
      }));
    console.log(
      `[statement][job:${jobId}] Page ${pageNum} [llm]: opening=${opening_balance}, closing=${closing_balance}, txns=${transactions.length}`
    );
    return { opening_balance, closing_balance, transactions };
  } catch {
    console.warn(`[statement][job:${jobId}] Page ${pageNum} returned non-JSON. Raw: ${raw.slice(0, 200)}`);
    return { opening_balance: null, closing_balance: null, transactions: [] };
  }
}

// ── PDF helpers ───────────────────────────────────────────────────────────────

/**
 * Validate file size, load the PDF, enforce page limit, and return per-page Buffers.
 */
async function splitPdfIntoPages(filePath: string): Promise<Buffer[]> {
  const fileSizeKb = fs.statSync(filePath).size / 1024;
  if (fileSizeKb > env.maxStatementFileSizeKb) {
    throw new Error(
      `File size ${fileSizeKb.toFixed(1)} KB exceeds the maximum allowed ${env.maxStatementFileSizeKb} KB.`
    );
  }

  const originalBytes = fs.readFileSync(filePath);
  const srcDoc = await PDFDocument.load(originalBytes);
  const totalPages = srcDoc.getPageCount();

  if (totalPages > env.maxStatementPages) {
    throw new Error(
      `File has ${totalPages} pages. Maximum allowed pages per statement is ${env.maxStatementPages}. ` +
        `This is a temporary limitation; please upload statements with smaller date ranges.`
    );
  }

  const pageBuffers: Buffer[] = [];
  for (let i = 0; i < totalPages; i++) {
    const pageDoc = await PDFDocument.create();
    const [copied] = await pageDoc.copyPages(srcDoc, [i]);
    pageDoc.addPage(copied);
    const bytes = await pageDoc.save();
    pageBuffers.push(Buffer.from(bytes));
  }

  return pageBuffers;
}

/**
 * Extract plain text from a single-page PDF buffer using pdf-parse v2.
 */
async function extractPageText(pageBuffer: Buffer): Promise<string> {
  const parser = new PDFParse({ data: pageBuffer });
  const result = await parser.getText();
  return result.text.trim();
}

// ── Per-page LLM call ─────────────────────────────────────────────────────────

async function callLlmPage(
  pageText: string,
  pageNum: number,
  totalPages: number,
  jobId: string
): Promise<string> {
  const prompt = buildPagePrompt(pageNum, totalPages, pageText);
  const label = `job:${jobId}/page:${pageNum}`;
  return callLlm(prompt, label);
}

// ── Main async pipeline ───────────────────────────────────────────────────────

export async function processStatement(
  jobId: string,
  userId: bigint,
  accountId: bigint,
  filePath: string,
  isLatestStatement: boolean | null
): Promise<void> {
  try {
    await jobRepo.updateJobStatus(
      pool,
      jobId,
      "PROCESSING",
      "Extracting transactions..."
    );

    // ── Step 1: Validate size + split into per-page buffers ──────────────────
    const pageBuffers = await splitPdfIntoPages(filePath);
    const totalPages = pageBuffers.length;
    console.log(`[statement][job:${jobId}] PDF split into ${totalPages} page(s)`);

    // ── Step 2: Extract text from each page ──────────────────────────────────
    const pageTexts = await Promise.all(pageBuffers.map(extractPageText));
    console.log(
      `[statement][job:${jobId}] Text extracted. Char counts per page: [${pageTexts.map((t) => t.length).join(", ")}]`
    );

    // Warn about suspiciously empty pages (likely image-based)
    pageTexts.forEach((text, i) => {
      if (text.length < 50) {
        console.warn(
          `[statement][job:${jobId}] Page ${i + 1} has very little text (${text.length} chars) — may be image-based.`
        );
      }
    });

    // ── Step 3: Custom parser first, LLM fallback for unresolved pages ───────
    type TaggedTransaction = LlmTransaction & { pageNum: number; localIdx: number };
    type PageResultEntry   = LlmPageResult & { pageNum: number };

    const pageResults: PageResultEntry[] = new Array(totalPages);
    const llmNeeded: number[] = [];  // 1-indexed page numbers that need LLM

    // Detect bank format on the full concatenated text (first page usually has the header)
    const isAxisBank = isAxisBankPage(pageTexts[0] ?? "");
    console.log(`[statement][job:${jobId}] Bank detection: ${isAxisBank ? "Axis Bank → custom parser" : "unknown → LLM only"}`);

    // 3a: Try custom parser for each page (only if bank detected)
    for (let i = 0; i < totalPages; i++) {
      const pageNum = i + 1;
      if (!isAxisBank) {
        llmNeeded.push(pageNum);
        continue;
      }
      try {
        const result = parseAxisBankPage(pageTexts[i]);
        const hasDatePatterns = /\d{2}-\d{2}-\d{4}/.test(pageTexts[i]);
        if (result.transactions.length > 0 || !hasDatePatterns) {
          console.log(
            `[statement][job:${jobId}] Page ${pageNum} [custom]: opening=${result.opening_balance}, closing=${result.closing_balance}, txns=${result.transactions.length}`
          );
          pageResults[i] = { pageNum, ...result };
        } else {
          console.warn(`[statement][job:${jobId}] Page ${pageNum} [custom]: 0 txns but date patterns found — falling back to LLM`);
          llmNeeded.push(pageNum);
        }
      } catch (err) {
        console.warn(`[statement][job:${jobId}] Page ${pageNum} [custom]: error — falling back to LLM: ${err}`);
        llmNeeded.push(pageNum);
      }
    }

    // 3b: LLM for remaining pages (batched, max 3 parallel)
    if (llmNeeded.length > 0) {
      console.log(`[statement][job:${jobId}] LLM needed for pages: [${llmNeeded.join(", ")}]`);
      const BATCH_SIZE = 3;

      for (let batchStart = 0; batchStart < llmNeeded.length; batchStart += BATCH_SIZE) {
        const batch = llmNeeded.slice(batchStart, batchStart + BATCH_SIZE);
        const batchLast = batch[batch.length - 1];

        await jobRepo.updateJobStatus(
          pool, jobId, "PROCESSING",
          batch.length === 1
            ? `Extracting transactions... (page ${batch[0]} of ${totalPages})`
            : `Extracting transactions... (pages ${batch[0]}–${batchLast} of ${totalPages})`
        );

        const rawOutputs = await Promise.all(
          batch.map((pageNum) => callLlmPage(pageTexts[pageNum - 1], pageNum, totalPages, jobId))
        );

        rawOutputs.forEach((raw, k) => {
          const pageNum = batch[k];
          pageResults[pageNum - 1] = {
            pageNum,
            ...parseLlmRawOutput(raw, pageNum, jobId),
          };
        });
      }
    } else {
      console.log(`[statement][job:${jobId}] All pages parsed by custom parser — LLM not needed`);
      await jobRepo.updateJobStatus(pool, jobId, "PROCESSING", `Extracting transactions... (page ${totalPages} of ${totalPages})`);
    }

    // ── Step 5: Resolve opening/closing balances ──────────────────────────────
    // Opening = first valid occurrence scanning forward
    let openingBalance: number | null = null;
    for (const page of pageResults) {
      if (page.opening_balance !== null) {
        openingBalance = page.opening_balance;
        console.log(
          `[statement][job:${jobId}] Opening balance ${openingBalance} found on page ${page.pageNum}`
        );
        break;
      }
    }

    // Closing = last valid occurrence scanning backward
    let closingBalance: number | null = null;
    for (let i = pageResults.length - 1; i >= 0; i--) {
      if (pageResults[i].closing_balance !== null) {
        closingBalance = pageResults[i].closing_balance;
        console.log(
          `[statement][job:${jobId}] Closing balance ${closingBalance} found on page ${pageResults[i].pageNum}`
        );
        break;
      }
    }

    // ── Step 6: Merge transactions maintaining page → local order ─────────────
    const allTagged: TaggedTransaction[] = pageResults.flatMap((page) =>
      page.transactions.map((t, localIdx) => ({
        ...t,
        pageNum: page.pageNum,
        localIdx,
      }))
    );

    const totalExtractedRaw = allTagged.length;

    // ── Step 7: VALIDATING ────────────────────────────────────────────────────
    await jobRepo.updateJobStatus(pool, jobId, "VALIDATING", "Validating data...");

    // Normalize — sort by date ASC (stable: preserves page→local order within same date)
    const normalized = allTagged
      .map((t) => {
        const typeUpper = (t.type ?? "").toUpperCase();
        if (typeUpper !== "CREDIT" && typeUpper !== "DEBIT") {
          throw new Error(
            `Transaction[page ${t.pageNum}, local ${t.localIdx}] has invalid type: "${t.type}"`
          );
        }
        return {
          date: normalizeDate(t.date),
          description: normalizeDescription(t.description ?? ""),
          descriptionReadable: (t.description_human_readable ?? "").trim() || null,
          amount: normalizeAmount(t.amount),
          type: typeUpper as "CREDIT" | "DEBIT",
          pageNum: t.pageNum,
          localIdx: t.localIdx,
        };
      })
      // Sort by date ASC only — stable sort preserves page→local order within same date
      .sort((a, b) => a.date.localeCompare(b.date))
      // Assign global statement_seq after sorting
      .map((t, idx) => ({ ...t, seq: idx }));

    // ── TEST ONLY: drop 2 transactions to force AWAITING_CONFIRMATION ────────
    // TODO: remove before prod
    // normalized.splice(0, 2);
    // ─────────────────────────────────────────────────────────────────────────

    const totalExtracted = normalized.length;

    // ── Step 7b: Balance validation + delta classification ───────────────────
    //
    // allowed_delta = (total_extracted / 3) * 10
    //   delta > allowed_delta  → ERROR  (likely missing transactions)
    //   0 < delta ≤ allowed_delta → WARNING (minor rounding / partial page)
    //   delta == 0             → OK     (perfect match or no balance info)
    //
    // On ERROR or WARNING we pause in AWAITING_CONFIRMATION so the user can
    // decide whether to insert a balancing dummy transaction or discard.

    let delta = 0;
    let deltaStatus: "OK" | "WARNING" | "ERROR" = "OK";
    let allowedDelta = 0;
    let dummyType: "CREDIT" | "DEBIT" | null = null;
    // latest date among all extracted transactions (used for dummy transaction date)
    const latestDate = normalized.reduce(
      (max, t) => (t.date > max ? t.date : max),
      normalized[0]?.date ?? ""
    );

    if (openingBalance !== null && closingBalance !== null) {
      const totalCredits = normalized
        .filter((t) => t.type === "CREDIT")
        .reduce((sum, t) => sum + parseFloat(t.amount), 0);
      const totalDebits = normalized
        .filter((t) => t.type === "DEBIT")
        .reduce((sum, t) => sum + parseFloat(t.amount), 0);

      const expectedClosing = openingBalance + totalCredits - totalDebits;
      const diff = expectedClosing - closingBalance; // positive → expected > actual → add DEBIT to reconcile

      console.log(
        `[statement][job:${jobId}] Balance check:\n` +
          `  opening_balance  : ${openingBalance.toFixed(2)}\n` +
          `  total_credits    : +${totalCredits.toFixed(2)} (${normalized.filter((t) => t.type === "CREDIT").length} txns)\n` +
          `  total_debits     : -${totalDebits.toFixed(2)} (${normalized.filter((t) => t.type === "DEBIT").length} txns)\n` +
          `  expected_closing : ${expectedClosing.toFixed(2)}\n` +
          `  actual_closing   : ${closingBalance.toFixed(2)}\n` +
          `  difference       : ${diff.toFixed(2)}\n` +
          `  result           : ${Math.abs(diff) <= 1 ? "✅ PASS" : "❌ MISMATCH"}`
      );

      if (Math.abs(diff) > 1) {
        delta = parseFloat(Math.abs(diff).toFixed(2));
        allowedDelta = parseFloat(((totalExtracted / 3) * 10).toFixed(2));
        deltaStatus = delta > allowedDelta ? "ERROR" : "WARNING";
        // If expected > actual: we overcounted credits / undercounted debits → insert DEBIT to reconcile
        dummyType = diff > 0 ? "DEBIT" : "CREDIT";

        const topByAmount = [...normalized]
          .sort((a, b) => parseFloat(b.amount) - parseFloat(a.amount))
          .slice(0, 10);
        console.warn(
          `[statement][job:${jobId}] ⚠️  Balance mismatch — delta=${delta}, allowedDelta=${allowedDelta}, status=${deltaStatus}, dummyType=${dummyType}\n` +
            `  Top 10 transactions by amount:\n` +
            topByAmount
              .map(
                (t) =>
                  `  [pg${t.pageNum}][${t.date}] ${t.type.padEnd(6)} ${parseFloat(t.amount).toFixed(2).padStart(12)}  ${t.description.slice(0, 60)}`
              )
              .join("\n")
        );
      }
    } else {
      console.warn(
        `[statement][job:${jobId}] ⚠️  Balance validation skipped — ` +
          `opening=${openingBalance}, closing=${closingBalance} (not found across all pages)`
      );
      // Cannot compute delta; proceed directly to save without confirmation prompt
    }

    // ── Step 8: Build items and deduplicate ───────────────────────────────────
    const items: StatementDraftItem[] = normalized.map((t) => {
      const fp = computeFingerprint(accountId, t.date, t.amount, t.description, t.type);
      return {
        direction: (t.type === "CREDIT" ? "credit" : "debit") as Direction,
        amount: t.amount,
        description: t.description,
        descriptionReadable: t.descriptionReadable,
        transactionDate: t.date,
        statementSeq: t.seq,
        fingerprint: fp,
      };
    });

    const allFingerprints = items.map((i) => i.fingerprint);
    const existing = await txRepo.findExistingFingerprints(pool, allFingerprints, userId);
    const newItems = items.filter((i) => !existing.has(i.fingerprint));
    const skippedItems = items.filter((i) => existing.has(i.fingerprint));
    const duplicatesSkipped = skippedItems.length;

    // ── Step 8c: Account balance reconciliation check ─────────────────────────
    //
    // Projected balance after settling everything this statement covers:
    //   projected = account.total_balance
    //             + net(existing statement drafts, source='statement' only)
    //             + net(new items from this upload)
    //
    // We exclude manual drafts to avoid double-counting transactions that appear
    // in both a manual draft and the current statement import.
    //
    // Gate conditions (all must be true):
    //   1. closingBalance was found in the statement
    //   2. isLatestStatement !== false  (user didn't explicitly say "not latest")
    //   3. isLatestStatement === true   (user flagged it)
    //      OR  latestDate >= yesterday  (auto-detect: statement likely current)

    const todayUtc     = new Date().toISOString().slice(0, 10);
    const yesterdayUtc = new Date(Date.now() - 86_400_000).toISOString().slice(0, 10);
    const autoDetect   = latestDate >= yesterdayUtc;
    const runAcctCheck =
      closingBalance !== null &&
      isLatestStatement !== false &&
      (isLatestStatement === true || autoDetect);

    let acctDelta: number | null           = null;
    let acctDummyType: "CREDIT" | "DEBIT" | null = null;
    let acctDbBalance: number | null       = null;
    let acctProjectedBalance: number | null = null;

    if (runAcctCheck) {
      const accRow = await pool.query<{ total_balance: string }>(
        `SELECT total_balance::text FROM accounts WHERE id = $1 AND user_id = $2`,
        [accountId, userId]
      );
      const dbBalance = parseFloat(accRow.rows[0]?.total_balance ?? "0");

      const existingNet = await txRepo.getNetStatementDrafts(pool, userId, accountId);

      const newItemsNet = newItems.reduce((sum, item) => {
        const amt = parseFloat(item.amount);
        return sum + (item.direction === "credit" ? amt : -amt);
      }, 0);

      const projected = dbBalance + existingNet.net + newItemsNet;
      // positive diff → statement CB > projected → need CREDIT to bring projected up
      const diff = closingBalance! - projected;

      acctDbBalance        = dbBalance;
      acctProjectedBalance = parseFloat(projected.toFixed(2));

      console.log(
        `[statement][job:${jobId}] Account balance check:\n` +
          `  db_balance        : ${dbBalance.toFixed(2)}\n` +
          `  existing_stmt_net : ${existingNet.net.toFixed(2)} (credits=${existingNet.netCredits.toFixed(2)}, debits=${existingNet.netDebits.toFixed(2)})\n` +
          `  new_items_net     : ${newItemsNet.toFixed(2)}\n` +
          `  projected_balance : ${projected.toFixed(2)}\n` +
          `  statement_closing : ${closingBalance!.toFixed(2)}\n` +
          `  difference        : ${diff.toFixed(2)}\n` +
          `  result            : ${Math.abs(diff) <= 1 ? "✅ PASS" : "⚠️  MISMATCH"}`
      );

      if (Math.abs(diff) > 1) {
        acctDelta     = parseFloat(Math.abs(diff).toFixed(2));
        acctDummyType = diff > 0 ? "CREDIT" : "DEBIT";
        console.warn(
          `[statement][job:${jobId}] ⚠️  Account balance mismatch — acctDelta=${acctDelta}, dummyType=${acctDummyType}`
        );
      }
    } else {
      console.log(
        `[statement][job:${jobId}] Account balance check skipped — ` +
          `closingBalance=${closingBalance}, isLatestStatement=${isLatestStatement}, ` +
          `autoDetect=${autoDetect} (latestDate=${latestDate}, today=${todayUtc})`
      );
    }

    // ── Step 8b: If either check requires confirmation, pause here ────────────
    if (deltaStatus !== "OK" || acctDelta !== null) {
      await jobRepo.setAwaitingConfirmation(pool, jobId, {
        pending_transactions: newItems,
        total_extracted: totalExtracted,
        duplicates_skipped: duplicatesSkipped,
        delta,
        allowed_delta: allowedDelta,
        delta_status: deltaStatus,
        dummy_type: dummyType,
        latest_date: latestDate,
        acct_delta: acctDelta,
        acct_dummy_type: acctDummyType,
        acct_db_balance: acctDbBalance,
        acct_projected_balance: acctProjectedBalance,
        acct_closing_balance: closingBalance,
      });
      console.log(
        `[statement][job:${jobId}] ⏸  AWAITING_CONFIRMATION — ` +
          `delta=${delta} (allowed=${allowedDelta}), status=${deltaStatus}, ` +
          `acctDelta=${acctDelta}, pendingToInsert=${newItems.length}`
      );
      return;
    }

    // ── Step 9: SAVING — insert drafts ────────────────────────────────────────
    await jobRepo.updateJobStatus(pool, jobId, "SAVING", "Saving drafts...");

    // Sample log — one inserted and one skipped for quick visual verification
    const sampleInserted = newItems[0];
    const sampleSkipped = skippedItems[0];
    if (sampleInserted) {
      console.log(
        `[statement][job:${jobId}] 🟢 Sample inserted:  ${sampleInserted.transactionDate} | ${sampleInserted.direction.toUpperCase()} ${sampleInserted.amount} | "${sampleInserted.descriptionReadable ?? sampleInserted.description}"`
      );
    }
    if (sampleSkipped) {
      console.log(
        `[statement][job:${jobId}] 🟡 Sample skipped:   ${sampleSkipped.transactionDate} | ${sampleSkipped.direction.toUpperCase()} ${sampleSkipped.amount} | "${sampleSkipped.descriptionReadable ?? sampleSkipped.description}"`
      );
    }

    const totalInserted = await txRepo.insertStatementDrafts(pool, userId, accountId, newItems);

    // ── Step 10: COMPLETED ────────────────────────────────────────────────────
    await jobRepo.completeJob(pool, jobId, {
      total_extracted: totalExtracted,
      total_inserted: totalInserted,
      duplicates_skipped: duplicatesSkipped,
      validation_status: "SUCCESS",
    });

    console.log(
      `[statement][job:${jobId}] ✅ Done — extracted=${totalExtracted} (raw=${totalExtractedRaw}), inserted=${totalInserted}, skipped=${duplicatesSkipped}`
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown processing error";
    console.error(`[statement][job:${jobId}] ❌ Failed: ${message}`);
    await jobRepo.failJob(pool, jobId, message);
  } finally {
    try {
      unlinkSync(filePath);
    } catch {
      // Non-fatal
    }
  }
}
