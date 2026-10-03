import { env } from "../config/env.js";
import type { RawTradeEntry, BatchValidationResult } from "./investmentsLlmParsingService.js";

/**
 * Per-trade sanity check: amount ≈ units × price, within a generous tolerance
 * (max of an absolute floor and a relative percentage) to absorb brokerage/
 * rounding noise without masking real LLM extraction errors.
 */
export function checkAmountSanity(
  units: number,
  price: number,
  amount: number
): { valid: boolean; reason?: string } {
  const expected = units * price;
  const tolerance = Math.max(
    env.investmentsAmountToleranceAbs,
    Math.abs(amount) * env.investmentsAmountTolerancePct
  );
  const diff = Math.abs(expected - amount);
  if (diff > tolerance) {
    return {
      valid: false,
      reason:
        `amount ${amount.toFixed(2)} does not reconcile with units(${units}) x price(${price}) ` +
        `= ${expected.toFixed(2)} (diff ${diff.toFixed(2)} > tolerance ${tolerance.toFixed(2)})`,
    };
  }
  return { valid: true };
}

export function validateTradeBatch(entries: RawTradeEntry[]): BatchValidationResult {
  const failures: string[] = [];
  for (const e of entries) {
    const result = checkAmountSanity(e.units, e.price, e.amount);
    if (!result.valid) {
      failures.push(`${e.isin} ${e.transactionType} ${e.transactionDate}: ${result.reason}`);
    }
  }
  return { valid: failures.length === 0, failures };
}
