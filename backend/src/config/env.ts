import dotenv from "dotenv";

dotenv.config();

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

export const env = {
  port: Number(process.env.PORT ?? "3000"),
  databaseUrl: requireEnv("DATABASE_URL"),
  staticOtp: requireEnv("STATIC_OTP"),
  corsOrigin: process.env.CORS_ORIGIN ?? "*",
  // LLM provider — "gemini" | "grok" | "openai"  (default: grok)
  llmProvider: (process.env.LLM_PROVIDER ?? "grok") as "gemini" | "grok" | "openai",
  geminiApiKey: process.env.GEMINI_API_KEY ?? "",
  // gemini-1.5-flash has a more generous free-tier quota than 2.0-flash.
  // Override with GEMINI_MODEL=gemini-2.0-flash once on a paid plan.
  geminiModel: process.env.GEMINI_MODEL ?? "gemini-2.5-flash-lite",
  // Grok (xAI) — required only when LLM_PROVIDER=grok
  grokApiKey: process.env.GROK_API_KEY ?? "",
  grokModel: process.env.GROK_MODEL ?? "grok-3-mini",
  // OpenAI — required only when LLM_PROVIDER=openai
  openaiApiKey: process.env.OPENAI_API_KEY ?? "",
  openaiModel: process.env.OPENAI_MODEL ?? "gpt-4o-mini",
  // Statement upload limits (override via env vars)
  maxStatementPages: parseInt(process.env.MAX_STATEMENT_PAGES ?? "10", 10),
  maxStatementFileSizeKb: parseInt(process.env.MAX_STATEMENT_FILE_SIZE_KB ?? "200", 10),

  // ── Investments (independent config, additive only) ──────────────────────
  // Per-trade "amount ≈ units × price" sanity tolerance: max(absolute, relative).
  investmentsAmountToleranceAbs: parseFloat(process.env.INVESTMENTS_AMOUNT_TOLERANCE_ABS ?? "1"),
  investmentsAmountTolerancePct: parseFloat(process.env.INVESTMENTS_AMOUNT_TOLERANCE_PCT ?? "0.01"),
  // Rows per LLM call when parsing Holdings/Trade Book spreadsheets.
  investmentsExcelRowBatchSize: parseInt(process.env.INVESTMENTS_EXCEL_ROW_BATCH_SIZE ?? "60", 10),
  // Safety cap on data rows per worksheet.
  investmentsMaxExcelRows: parseInt(process.env.INVESTMENTS_MAX_EXCEL_ROWS ?? "5000", 10),
  // Max size per uploaded file (Holdings / Trade Book), in KB.
  investmentsMaxUploadFileSizeKb: parseInt(
    process.env.INVESTMENTS_MAX_UPLOAD_FILE_SIZE_KB ?? "10000",
    10
  ),
  // Manual price refresh (tigzig NAV API) — Mutual Fund/ETF assets only.
  investmentsTigzigNavUrl:
    process.env.INVESTMENTS_TIGZIG_NAV_URL ?? "https://api.tigzig.com/mf/v1/nav",
  // Max ISINs per external API call — batched to keep query strings/responses small.
  investmentsPriceRefreshBatchSize: parseInt(
    process.env.INVESTMENTS_PRICE_REFRESH_BATCH_SIZE ?? "50",
    10
  ),
  investmentsPriceRefreshTimeoutMs: parseInt(
    process.env.INVESTMENTS_PRICE_REFRESH_TIMEOUT_MS ?? "15000",
    10
  ),
};
