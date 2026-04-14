/**
 * Test script: extract text from a PDF using pdf-parse v2.x
 * Usage: npx tsx src/scripts/pdfParseTest.ts <path-to-pdf>
 * Output: .logs/<pdf-filename>.txt
 */

import fs from "fs";
import path from "path";
import { PDFParse } from "pdf-parse";

const filePath = "/Users/welcome/Documents/other/statements/big_AcctStatement_XXX7918_12042026.pdf";
if (!filePath) {
  console.error("Usage: npx tsx src/scripts/pdfParseTest.ts <path-to-pdf>");
  process.exit(1);
}

if (!fs.existsSync(filePath)) {
  console.error(`File not found: ${filePath}`);
  process.exit(1);
}

// Ensure .logs/ exists next to this repo root (backend/)
const logsDir = path.resolve(".", ".logs");
if (!fs.existsSync(logsDir)) {
  fs.mkdirSync(logsDir, { recursive: true });
}

console.log(`\nParsing: ${filePath}\n${"─".repeat(60)}`);

const dataBuffer = fs.readFileSync(filePath);
const parser = new PDFParse({ data: dataBuffer });

const result = await parser.getText();

console.log(`Pages  : ${result.total}`);
console.log(`Chars  : ${result.text.length}`);

// Build output: header + per-page sections
const pdfName = path.basename(filePath);
const lines: string[] = [];

lines.push(`PDF    : ${filePath}`);
lines.push(`Pages  : ${result.total}`);
lines.push(`Chars  : ${result.text.length}`);
lines.push(`${"─".repeat(60)}`);
lines.push("");

for (const page of result.pages) {
  lines.push(`── Page ${page.num} ${"─".repeat(50)}`);
  lines.push(cleanText(page.text));
  lines.push("");
}

const outputPath = path.join(logsDir, `${pdfName}.txt`);
fs.writeFileSync(outputPath, lines.join("\n"), "utf8");

console.log(`${"─".repeat(60)}`);
console.log(`✅  Extracted text written to: ${outputPath}`);

function cleanText(raw: string): string {
  return raw
    .replace(/\r\n?/g, "\n")       // normalize line endings
    .replace(/[ \t]{2,}/g, "  ")   // collapse repeated spaces/tabs to 2 spaces (preserves column alignment)
    .replace(/\n{3,}/g, "\n\n")    // max 2 consecutive blank lines
    .trim();
}
