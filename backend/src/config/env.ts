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
};
