import { randomInt } from "crypto";

/** Monotonic-ish unique positive bigint for primary keys */
export function nextId(): bigint {
  const t = BigInt(Date.now());
  const r = BigInt(randomInt(0, 1_000_000));
  return t * 1_000_000n + r;
}
