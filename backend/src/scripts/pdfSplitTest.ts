/**
 * Test script: split a PDF into individual page PDFs, then extract text from each.
 * Usage: npx tsx src/scripts/pdfSplitTest.ts <path-to-pdf>
 *
 * Output (in .logs/<pdf-name>/):
 *   page-01.pdf       ← single-page PDF
 *   page-01.txt       ← extracted text for that page
 *   page-02.pdf
 *   page-02.txt
 *   ...
 *   summary.txt       ← all pages combined with separators
 */

import fs from "fs";
import path from "path";
import { PDFDocument } from "pdf-lib";
import { PDFParse } from "pdf-parse";

const filePath = "/Users/welcome/Documents/other/statements/big_AcctStatement_XXX7918_12042026.pdf";
if (!filePath) {
  console.error("Usage: npx tsx src/scripts/pdfSplitTest.ts <path-to-pdf>");
  process.exit(1);
}
if (!fs.existsSync(filePath)) {
  console.error(`File not found: ${filePath}`);
  process.exit(1);
}

const pdfName = path.basename(filePath, path.extname(filePath));

// Output dir: .logs/<pdf-name>/
const outDir = path.resolve(".", ".logs", pdfName);
fs.mkdirSync(outDir, { recursive: true });

console.log(`\nInput  : ${filePath}`);
console.log(`Output : ${outDir}`);
console.log(`${"─".repeat(60)}`);

// ── Step 1: Load original PDF and get total page count ───────────────────────

const originalBytes = fs.readFileSync(filePath);
const srcDoc = await PDFDocument.load(originalBytes);
const totalPages = srcDoc.getPageCount();

console.log(`Pages  : ${totalPages}`);
console.log(`${"─".repeat(60)}\n`);

// ── Step 2: For each page — copy to single-page PDF + extract text ───────────

const summaryLines: string[] = [
  `PDF    : ${filePath}`,
  `Pages  : ${totalPages}`,
  `${"─".repeat(60)}`,
  "",
];

const pad = String(totalPages).length; // e.g. 3 if 100+ pages

for (let i = 0; i < totalPages; i++) {
  const pageNum = i + 1;
  const label = String(pageNum).padStart(pad, "0");

  // ── Split: create a new PDF with just this one page ──────────────────────
  const pageDoc = await PDFDocument.create();
  const [copiedPage] = await pageDoc.copyPages(srcDoc, [i]);
  pageDoc.addPage(copiedPage);
  const pageBytes = await pageDoc.save();

  const pagePdfPath = path.join(outDir, `page-${label}.pdf`);
  fs.writeFileSync(pagePdfPath, pageBytes);

  // ── Extract: parse text from the single-page PDF ─────────────────────────
  const parser = new PDFParse({ data: Buffer.from(pageBytes) });
  const result = await parser.getText();
  const cleaned = cleanText(result.text);

  const pageTxtPath = path.join(outDir, `page-${label}.txt`);
  fs.writeFileSync(pageTxtPath, cleaned, "utf8");

  console.log(`  Page ${pageNum}/${totalPages}  →  ${cleaned.length} chars  [page-${label}.pdf / .txt]`);

  // Accumulate into summary
  summaryLines.push(`── Page ${pageNum} ${"─".repeat(50)}`);
  summaryLines.push(cleaned);
  summaryLines.push("");
}

// ── Step 3: Write combined summary ──────────────────────────────────────────

const summaryPath = path.join(outDir, "summary.txt");
fs.writeFileSync(summaryPath, summaryLines.join("\n"), "utf8");

console.log(`\n${"─".repeat(60)}`);
console.log(`✅  Done. Files written to: ${outDir}`);
console.log(`   • page-XX.pdf  — single-page PDFs`);
console.log(`   • page-XX.txt  — extracted text per page`);
console.log(`   • summary.txt  — all pages combined`);

// ── Helpers ──────────────────────────────────────────────────────────────────

function cleanText(raw: string): string {
  return raw
    .replace(/\r\n?/g, "\n")       // normalize line endings
    .replace(/[ \t]{2,}/g, "  ")   // collapse repeated spaces/tabs (preserves column alignment)
    .replace(/\n{3,}/g, "\n\n")    // max 2 consecutive blank lines
    .trim();
}
