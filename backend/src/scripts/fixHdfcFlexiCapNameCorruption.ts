/**
 * ONE-TIME CORRECTIVE SCRIPT — fixes a single, already-corrupted
 * `investments_assets.name` row left over from an LLM-hallucination bug
 * in the upload pipeline (see `resolveAssetIdentity` in
 * `investmentsUploadProcessingService.ts`, which was the actual pipeline
 * fix for this).
 *
 * Reported by user kamesh5.nkr@gmail.com for account "My Demat Account 1":
 * a Trade Book row for ISIN INF200K01RP8 (174.267 units @ 44.4697, exactly
 * matching the source file) came back from the LLM with name
 * "HDFC Flexi Cap Fund" instead of the correct fund name — a name that does
 * not appear anywhere in either the uploaded Holdings or Trade Book file
 * (verified by direct inspection of the source .xlsx files). Because
 * `investments_assets` is a GLOBAL table keyed by ISIN (not per-user), that
 * one bad row corrupted the shared asset record, which is why BOTH the real
 * trade and its auto-generated reconciliation dummy trade displayed the
 * wrong name in the UI.
 *
 * The Holdings file independently reports the correct name twice (as a
 * duplicate restatement across two sheets, both agreeing) as
 * "SBI GOLD FUND - DIRECT PLAN" for this same ISIN — the same majority-vote
 * logic now built into `resolveAssetIdentity` would have picked this name
 * had the pipeline fix been in place at upload time.
 *
 * This script only ever touches the ONE specific (isin, corrupted-name)
 * pair below, and only if the name in the DB today still exactly matches
 * the known-bad value — so it is safe to re-run any number of times
 * (no-op once already fixed), and cannot accidentally touch any other
 * asset row.
 *
 * Usage:
 *   npx tsx src/scripts/fixHdfcFlexiCapNameCorruption.ts
 */

import { pool } from "../db/pool.js";

const ISIN = "INF200K01RP8";
const CORRUPTED_NAME = "HDFC Flexi Cap Fund";
const CORRECTED_NAME = "SBI GOLD FUND - DIRECT PLAN";

async function main(): Promise<void> {
  const { rows } = await pool.query<{ id: string; name: string; version: number }>(
    `SELECT id::text, name, version FROM investments_assets WHERE isin = $1`,
    [ISIN]
  );

  if (rows.length === 0) {
    console.log(`No asset found for ISIN ${ISIN} — nothing to fix.`);
    await pool.end();
    return;
  }

  const asset = rows[0]!;
  if (asset.name !== CORRUPTED_NAME) {
    console.log(
      `Asset ${asset.id} for ISIN ${ISIN} has name "${asset.name}" (not the known-bad ` +
        `"${CORRUPTED_NAME}") — already fixed or never corrupted. Nothing to do.`
    );
    await pool.end();
    return;
  }

  await pool.query(
    `UPDATE investments_assets SET name = $1, version = version + 1, updated_at = now() WHERE id = $2`,
    [CORRECTED_NAME, asset.id]
  );

  console.log(
    `Fixed asset ${asset.id} (ISIN ${ISIN}): "${CORRUPTED_NAME}" -> "${CORRECTED_NAME}" ` +
      `(version ${asset.version} -> ${asset.version + 1}).`
  );

  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
