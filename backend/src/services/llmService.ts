/**
 * LLM Service — abstraction over multiple providers.
 *
 * To switch providers set LLM_PROVIDER in .env:
 *   LLM_PROVIDER=gemini | grok | openai
 */

import { GoogleGenerativeAI } from "@google/generative-ai";
import OpenAI from "openai";
import { env } from "../config/env.js";

// Active provider is read from LLM_PROVIDER env var (default: "grok").
const ACTIVE_PROVIDER = env.llmProvider;

// ── Provider clients (lazily validated at call time) ─────────────────────────

const geminiClient = new GoogleGenerativeAI(env.geminiApiKey);

const grokClient = new OpenAI({
  apiKey: env.grokApiKey,
  baseURL: "https://api.x.ai/v1",
});

const openaiClient = new OpenAI({
  apiKey: env.openaiApiKey,
});

// ── Retry helpers ─────────────────────────────────────────────────────────────

function parseRetryDelay(errMessage: string, defaultMs = 65_000): number {
  const match = /retry in ([\d.]+)s/i.exec(errMessage);
  if (match) {
    const secs = parseFloat(match[1]);
    if (!isNaN(secs)) return Math.ceil(secs * 1000) + 2_000;
  }
  return defaultMs;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Gemini ────────────────────────────────────────────────────────────────────

async function callGemini(
  prompt: string,
  label: string,
  maxAttempts = 3
): Promise<string> {
  const model = geminiClient.getGenerativeModel({ model: env.geminiModel });

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      console.log(`[llm][gemini][${label}] Sending prompt (${prompt.length} chars)`);
      const result = await model.generateContent(prompt);
      console.log(`[llm][gemini][${label}] Response received`);
      return result.response.text();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const is429 = msg.includes("429") || msg.toLowerCase().includes("quota");

      if (is429 && attempt < maxAttempts) {
        const waitMs = parseRetryDelay(msg);
        console.warn(
          `[llm][gemini][${label}] 429 on attempt ${attempt}/${maxAttempts}. ` +
            `Retrying in ${Math.round(waitMs / 1000)}s...`
        );
        await sleep(waitMs);
        continue;
      }

      if (is429) {
        throw new Error(
          `Gemini API quota exceeded after ${maxAttempts} attempts. ` +
            `Please wait a minute and try again, or check your API plan at https://ai.dev/rate-limit.`
        );
      }
      throw err;
    }
  }

  throw new Error("Gemini call failed after retries");
}

// ── Grok (xAI — OpenAI-compatible API) ───────────────────────────────────────

async function callGrok(
  prompt: string,
  label: string,
  maxAttempts = 3
): Promise<string> {
  if (!env.grokApiKey) {
    throw new Error("GROK_API_KEY is not set in environment variables.");
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      console.log(`[llm][grok][${label}] Sending prompt (${prompt.length} chars)`);
      const response = await grokClient.chat.completions.create({
        model: env.grokModel,
        messages: [{ role: "user", content: prompt }],
        temperature: 0,  // deterministic output for structured extraction
      });
      console.log(`[llm][grok][${label}] Response received`);

      const text = response.choices[0]?.message?.content ?? "";
      if (!text) throw new Error("Grok returned an empty response");
      return text;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const is429 =
        msg.includes("429") ||
        msg.toLowerCase().includes("rate limit") ||
        msg.toLowerCase().includes("quota");

      if (is429 && attempt < maxAttempts) {
        const waitMs = parseRetryDelay(msg, 15_000); // Grok rate limits are shorter
        console.warn(
          `[llm][grok][${label}] 429 on attempt ${attempt}/${maxAttempts}. ` +
            `Retrying in ${Math.round(waitMs / 1000)}s...`
        );
        await sleep(waitMs);
        continue;
      }

      if (is429) {
        throw new Error(
          `Grok API rate limit exceeded after ${maxAttempts} attempts. ` +
            `Please wait a moment and try again.`
        );
      }
      throw err;
    }
  }

  throw new Error("Grok call failed after retries");
}

// ── OpenAI ────────────────────────────────────────────────────────────────────

async function callOpenAI(
  prompt: string,
  label: string,
  maxAttempts = 3
): Promise<string> {
  if (!env.openaiApiKey) {
    throw new Error("OPENAI_API_KEY is not set in environment variables.");
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const response = await openaiClient.chat.completions.create({
        model: env.openaiModel,
        messages: [{ role: "user", content: prompt }],
        temperature: 0,
      });

      const text = response.choices[0]?.message?.content ?? "";
      if (!text) throw new Error("OpenAI returned an empty response");
      return text;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const is429 =
        msg.includes("429") ||
        msg.toLowerCase().includes("rate limit") ||
        msg.toLowerCase().includes("quota");

      if (is429 && attempt < maxAttempts) {
        const waitMs = parseRetryDelay(msg, 20_000);
        console.warn(
          `[llm][openai][${label}] 429 on attempt ${attempt}/${maxAttempts}. ` +
            `Retrying in ${Math.round(waitMs / 1000)}s...`
        );
        await sleep(waitMs);
        continue;
      }

      if (is429) {
        throw new Error(
          `OpenAI API rate limit exceeded after ${maxAttempts} attempts. ` +
            `Please wait a moment and try again.`
        );
      }
      throw err;
    }
  }

  throw new Error("OpenAI call failed after retries");
}

// ── Public interface ──────────────────────────────────────────────────────────

/**
 * Send a prompt to the active LLM provider and return the text response.
 * @param prompt  Full prompt string to send.
 * @param label   Short label for log lines (e.g. "job:abc/page:2").
 */
export async function callLlm(prompt: string, label: string): Promise<string> {
  console.log(`[llm][${ACTIVE_PROVIDER}][${label}] Sending prompt (${prompt.length} chars)`);
  const start = Date.now();

  let result: string;
  switch (ACTIVE_PROVIDER) {
    case "gemini": result = await callGemini(prompt, label); break;
    case "grok":   result = await callGrok(prompt, label);   break;
    case "openai": result = await callOpenAI(prompt, label); break;
  }

  console.log(`[llm][${ACTIVE_PROVIDER}][${label}] Response received in ${Date.now() - start}ms (${result.length} chars)`);
  return result;
}

export type { };
export { ACTIVE_PROVIDER };
