/**
 * TEST SCRIPT — Investments Pot reallocation (investmentsReallocationService)
 * against the REAL database.
 *
 * Replicates both worked examples from investments_pot_amounts_v2.log
 * exactly (the "reduce" and "increase" scenarios) and verifies the exact
 * resulting investments_pot_positions deltas, plus the safety guards
 * (insufficient-units, archived-pot, cross-user ownership) and the
 * priceless-asset exclusion rule from getReallocationData.
 *
 * Runs through the real repositories/services (never raw ad-hoc SQL for the
 * assertions themselves — only for test-fixture setup, e.g. archiving a Pot,
 * since there's no application-level "archive Pot" endpoint yet), using a
 * temporary test user + a cross-user test user that are created fresh and
 * fully deleted again at the end (or on failure — cleanup runs in a
 * `finally`), so this is safe to re-run any number of times.
 *
 * Usage:
 *   npx tsx src/scripts/investmentsReallocationTest.ts
 */

import { pool } from "../db/pool.js";
import * as userRepo from "../repositories/userRepository.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import * as assetRepo from "../repositories/investmentsAssetRepository.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import * as priceRepo from "../repositories/investmentsPriceRepository.js";
import {
  getReallocationData,
  executeReallocation,
  REALLOCATION_INSUFFICIENT_UNITS_MESSAGE,
  type ReallocationMovementInput,
} from "../services/investmentsReallocationService.js";
import { HttpError } from "../utils/errors.js";

const RUN_TAG = Date.now().toString(36);
const OWNER_EMAIL = `investmentstest_realloc_owner_${RUN_TAG}@phase9.test`;
const OTHER_EMAIL = `investmentstest_realloc_other_${RUN_TAG}@phase9.test`;
const ISIN_A1 = `INFREALLOCA1${RUN_TAG}`.slice(0, 20).toUpperCase();
const ISIN_A2 = `INFREALLOCA2${RUN_TAG}`.slice(0, 20).toUpperCase();
const ISIN_B1 = `INFREALLOCB1${RUN_TAG}`.slice(0, 20).toUpperCase();
const ISIN_B2 = `INFREALLOCB2${RUN_TAG}`.slice(0, 20).toUpperCase();
const ISIN_NOPRICE = `INFREALLOCNP${RUN_TAG}`.slice(0, 20).toUpperCase();

let pass = 0;
let fail = 0;

function ok(label: string): void {
  pass++;
  console.log(`  \u2713 ${label}`);
}

function bad(label: string, detail?: string): void {
  fail++;
  console.log(`  \u2717 ${label}`);
  if (detail) console.log(`      ${detail}`);
}

function assertEqual(label: string, actual: unknown, expected: unknown): void {
  if (actual === expected) {
    ok(label);
  } else {
    bad(label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertClose(label: string, actual: number, expected: number, epsilon = 0.0001): void {
  if (Math.abs(actual - expected) <= epsilon) {
    ok(label);
  } else {
    bad(label, `expected ~${expected}, got ${actual}`);
  }
}

async function assertThrowsHttp(
  label: string,
  fn: () => Promise<unknown>,
  expectedStatus: number,
  expectedMessageSubstring?: string
): Promise<void> {
  try {
    await fn();
    bad(label, "expected it to throw, but it succeeded");
  } catch (e) {
    if (!(e instanceof HttpError)) {
      bad(label, `expected an HttpError, got ${e instanceof Error ? e.constructor.name : String(e)}: ${e}`);
      return;
    }
    if (e.status !== expectedStatus) {
      bad(label, `expected status ${expectedStatus}, got ${e.status} ("${e.message}")`);
      return;
    }
    if (expectedMessageSubstring && !e.message.includes(expectedMessageSubstring)) {
      bad(label, `expected message to include "${expectedMessageSubstring}", got "${e.message}"`);
      return;
    }
    ok(label);
  }
}

async function cleanup(emails: string[], isins: string[]): Promise<void> {
  await pool.query(`DELETE FROM users WHERE email = ANY($1::text[])`, [emails]);
  await pool.query(`DELETE FROM investments_assets WHERE isin = ANY($1::text[])`, [isins]);
}

async function main(): Promise<void> {
  const allIsins = [ISIN_A1, ISIN_A2, ISIN_B1, ISIN_B2, ISIN_NOPRICE];
  await cleanup([OWNER_EMAIL, OTHER_EMAIL], allIsins);

  console.log("\n\u2500\u2500 Investments Pot reallocation (live DB) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n");

  const owner = await userRepo.createUser(pool, OWNER_EMAIL);
  const other = await userRepo.createUser(pool, OTHER_EMAIL);
  const account = await accountRepo.insertAccount(pool, owner.id, "Test Account", null);

  // ═══════════════════════════════════════════════════════════════════════
  // 1. "Reduce" scenario — exactly investments_pot_amounts_v2.log's first
  //    worked example: Pot 1 (100rs: asset1 6u@10, asset2 8u@5) reduced to
  //    80rs, 10rs each sent to Pot 2 and Pot 3 (both starting at 0rs).
  // ═══════════════════════════════════════════════════════════════════════
  console.log("1. Reduce scenario (Pot1 100rs -> 80rs, split 10rs/10rs to Pot2/Pot3)");

  const pot1 = await potRepo.insertPot(pool, owner.id, "TestPot1", null, "savings");
  const pot2 = await potRepo.insertPot(pool, owner.id, "TestPot2", null, "savings");
  const pot3 = await potRepo.insertPot(pool, owner.id, "TestPot3", null, "savings");

  const assetA1 = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: ISIN_A1,
    name: "Reallocation Test Asset 1",
    symbol: null,
    assetClass: "MUTUAL_FUND",
    amfiSchemeCode: null,
  });
  const assetA2 = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: ISIN_A2,
    name: "Reallocation Test Asset 2",
    symbol: null,
    assetClass: "MUTUAL_FUND",
    amfiSchemeCode: null,
  });
  const aa1 = await assetRepo.findOrCreateAccountAsset(pool, owner.id, account.id, assetA1.id);
  const aa2 = await assetRepo.findOrCreateAccountAsset(pool, owner.id, account.id, assetA2.id);

  await priceRepo.upsertLatestPrice(pool, assetA1.id, "10.0000", "2026-01-01", "TEST_SOURCE");
  await priceRepo.upsertLatestPrice(pool, assetA2.id, "5.0000", "2026-01-01", "TEST_SOURCE");

  // Seed Pot 1's starting positions directly (simulating prior real
  // allocations) — account-level investments_positions is irrelevant here
  // since reallocation never reads/writes it.
  await positionRepo.adjustPotPosition(pool, owner.id, pot1.id, aa1.id, "6");
  await positionRepo.adjustPotPosition(pool, owner.id, pot1.id, aa2.id, "8");

  const dataBefore = await getReallocationData(owner.id);
  const pot1Before = dataBefore.pots.find((p) => p.id === pot1.id.toString());
  const pot2Before = dataBefore.pots.find((p) => p.id === pot2.id.toString());
  assertEqual("1a. getReallocationData: Pot1 currentValue = 100.00", pot1Before?.currentValue, "100.00");
  assertEqual("1b. getReallocationData: Pot1 has 2 position entries", pot1Before?.positions.length, 2);
  assertEqual("1c. getReallocationData: Pot2 currentValue = 0.00 (no positions yet)", pot2Before?.currentValue, "0.00");

  const reduceMovements: ReallocationMovementInput[] = [
    { accountAssetId: aa1.id.toString(), fromPotId: pot1.id.toString(), toPotId: pot2.id.toString(), units: "0.75" },
    { accountAssetId: aa1.id.toString(), fromPotId: pot1.id.toString(), toPotId: pot3.id.toString(), units: "0.75" },
    { accountAssetId: aa2.id.toString(), fromPotId: pot1.id.toString(), toPotId: pot2.id.toString(), units: "0.5" },
    { accountAssetId: aa2.id.toString(), fromPotId: pot1.id.toString(), toPotId: pot3.id.toString(), units: "0.5" },
  ];
  const reduceResult = await executeReallocation(owner.id, reduceMovements);
  assertEqual("1d. executeReallocation: movedCount", reduceResult.movedCount, 4);

  assertClose(
    "1e. Pot1 asset1 position: 6.0 -> 4.5",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot1.id, aa1.id),
    4.5
  );
  assertClose(
    "1f. Pot1 asset2 position: 8.0 -> 7.0",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot1.id, aa2.id),
    7.0
  );
  assertClose(
    "1g. Pot2 asset1 position: 0 -> 0.75",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot2.id, aa1.id),
    0.75
  );
  assertClose(
    "1h. Pot3 asset1 position: 0 -> 0.75",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot3.id, aa1.id),
    0.75
  );
  assertClose(
    "1i. Pot2 asset2 position: 0 -> 0.5",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot2.id, aa2.id),
    0.5
  );
  assertClose(
    "1j. Pot3 asset2 position: 0 -> 0.5",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot3.id, aa2.id),
    0.5
  );

  const dataAfterReduce = await getReallocationData(owner.id);
  const pot1AfterReduce = dataAfterReduce.pots.find((p) => p.id === pot1.id.toString());
  const pot2AfterReduce = dataAfterReduce.pots.find((p) => p.id === pot2.id.toString());
  const pot3AfterReduce = dataAfterReduce.pots.find((p) => p.id === pot3.id.toString());
  assertEqual("1k. Pot1 currentValue after reduce = 80.00", pot1AfterReduce?.currentValue, "80.00");
  assertEqual("1l. Pot2 currentValue after reduce = 10.00", pot2AfterReduce?.currentValue, "10.00");
  assertEqual("1m. Pot3 currentValue after reduce = 10.00", pot3AfterReduce?.currentValue, "10.00");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. "Increase" scenario — exactly investments_pot_amounts_v2.log's second
  //    worked example, using a fresh set of Pots/assets so it's independent
  //    of section 1's resulting state.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n2. Increase scenario (Pot5 200rs -> 250rs, 25rs/25rs pulled from Pot4/Pot6)");

  const pot4 = await potRepo.insertPot(pool, owner.id, "TestPot4", null, "savings");
  const pot5 = await potRepo.insertPot(pool, owner.id, "TestPot5", null, "savings");
  const pot6 = await potRepo.insertPot(pool, owner.id, "TestPot6", null, "savings");

  const assetB1 = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: ISIN_B1,
    name: "Reallocation Test Asset 3",
    symbol: null,
    assetClass: "MUTUAL_FUND",
    amfiSchemeCode: null,
  });
  const assetB2 = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: ISIN_B2,
    name: "Reallocation Test Asset 4",
    symbol: null,
    assetClass: "MUTUAL_FUND",
    amfiSchemeCode: null,
  });
  const bb1 = await assetRepo.findOrCreateAccountAsset(pool, owner.id, account.id, assetB1.id);
  const bb2 = await assetRepo.findOrCreateAccountAsset(pool, owner.id, account.id, assetB2.id);

  await priceRepo.upsertLatestPrice(pool, assetB1.id, "10.0000", "2026-01-01", "TEST_SOURCE");
  await priceRepo.upsertLatestPrice(pool, assetB2.id, "5.0000", "2026-01-01", "TEST_SOURCE");

  // Pot4: 6u@10 + 8u@5 = 100rs. Pot5: 5u@10 + 30u@5 = 200rs. Pot6: 5u@10 + 50u@5 = 300rs.
  await positionRepo.adjustPotPosition(pool, owner.id, pot4.id, bb1.id, "6");
  await positionRepo.adjustPotPosition(pool, owner.id, pot4.id, bb2.id, "8");
  await positionRepo.adjustPotPosition(pool, owner.id, pot5.id, bb1.id, "5");
  await positionRepo.adjustPotPosition(pool, owner.id, pot5.id, bb2.id, "30");
  await positionRepo.adjustPotPosition(pool, owner.id, pot6.id, bb1.id, "5");
  await positionRepo.adjustPotPosition(pool, owner.id, pot6.id, bb2.id, "50");

  const dataBeforeIncrease = await getReallocationData(owner.id);
  const pot5Before = dataBeforeIncrease.pots.find((p) => p.id === pot5.id.toString());
  assertEqual("2a. getReallocationData: Pot5 currentValue = 200.00", pot5Before?.currentValue, "200.00");
  const pot6Before = dataBeforeIncrease.pots.find((p) => p.id === pot6.id.toString());
  assertEqual("2b. getReallocationData: Pot6 currentValue = 300.00", pot6Before?.currentValue, "300.00");

  const increaseMovements: ReallocationMovementInput[] = [
    { accountAssetId: bb1.id.toString(), fromPotId: pot4.id.toString(), toPotId: pot5.id.toString(), units: "1.25" },
    { accountAssetId: bb1.id.toString(), fromPotId: pot6.id.toString(), toPotId: pot5.id.toString(), units: "1.25" },
    { accountAssetId: bb2.id.toString(), fromPotId: pot4.id.toString(), toPotId: pot5.id.toString(), units: "2.5" },
    { accountAssetId: bb2.id.toString(), fromPotId: pot6.id.toString(), toPotId: pot5.id.toString(), units: "2.5" },
  ];
  const increaseResult = await executeReallocation(owner.id, increaseMovements);
  assertEqual("2c. executeReallocation: movedCount", increaseResult.movedCount, 4);

  const dataAfterIncrease = await getReallocationData(owner.id);
  const pot4After = dataAfterIncrease.pots.find((p) => p.id === pot4.id.toString());
  const pot5After = dataAfterIncrease.pots.find((p) => p.id === pot5.id.toString());
  const pot6After = dataAfterIncrease.pots.find((p) => p.id === pot6.id.toString());
  assertEqual("2d. Pot4 currentValue after increase = 75.00 (lost 25rs)", pot4After?.currentValue, "75.00");
  assertEqual("2e. Pot5 currentValue after increase = 250.00 (target hit exactly)", pot5After?.currentValue, "250.00");
  assertEqual("2f. Pot6 currentValue after increase = 275.00 (lost 25rs)", pot6After?.currentValue, "275.00");

  assertClose(
    "2g. Total asset1(bb1) units across Pot4+Pot5+Pot6 unchanged at 16.0",
    (await positionRepo.getPotPositionUnits(pool, owner.id, pot4.id, bb1.id)) +
      (await positionRepo.getPotPositionUnits(pool, owner.id, pot5.id, bb1.id)) +
      (await positionRepo.getPotPositionUnits(pool, owner.id, pot6.id, bb1.id)),
    16.0
  );
  assertClose(
    "2h. Total asset2(bb2) units across Pot4+Pot5+Pot6 unchanged at 88.0",
    (await positionRepo.getPotPositionUnits(pool, owner.id, pot4.id, bb2.id)) +
      (await positionRepo.getPotPositionUnits(pool, owner.id, pot5.id, bb2.id)) +
      (await positionRepo.getPotPositionUnits(pool, owner.id, pot6.id, bb2.id)),
    88.0
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 3. Insufficient-units guard — must reject atomically (no partial write)
  //    when a movement would drive a source Pot's position negative.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n3. Insufficient-units guard");

  const pot4Bb1Before = await positionRepo.getPotPositionUnits(pool, owner.id, pot4.id, bb1.id);
  await assertThrowsHttp(
    "3a. a movement exceeding the source Pot's position is rejected with the exact spec message",
    () =>
      executeReallocation(owner.id, [
        { accountAssetId: bb1.id.toString(), fromPotId: pot4.id.toString(), toPotId: pot5.id.toString(), units: "999" },
      ]),
    400,
    REALLOCATION_INSUFFICIENT_UNITS_MESSAGE
  );
  assertClose(
    "3b. rejected movement leaves the source Pot's position completely unchanged",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot4.id, bb1.id),
    pot4Bb1Before
  );

  // 3c. Aggregate-across-movements check: two movements pulling the same
  // asset from the same Pot, each individually fine but not together.
  await assertThrowsHttp(
    "3c. two movements that are fine individually but not in aggregate are rejected",
    () =>
      executeReallocation(owner.id, [
        {
          accountAssetId: bb1.id.toString(),
          fromPotId: pot4.id.toString(),
          toPotId: pot5.id.toString(),
          units: "3",
        },
        {
          accountAssetId: bb1.id.toString(),
          fromPotId: pot4.id.toString(),
          toPotId: pot6.id.toString(),
          units: "3",
        },
      ]),
    400,
    REALLOCATION_INSUFFICIENT_UNITS_MESSAGE
  );
  assertClose(
    "3d. rejected aggregate movement leaves the source Pot's position completely unchanged",
    await positionRepo.getPotPositionUnits(pool, owner.id, pot4.id, bb1.id),
    pot4Bb1Before
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 4. Archived-pot guard — an archived Pot can never be a source or target.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n4. Archived-pot guard");

  const archivedPot = await potRepo.insertPot(pool, owner.id, "ArchivedTestPot", null, "savings");
  // No application-level "archive" endpoint exists yet — set status directly
  // for this test fixture only.
  await pool.query(`UPDATE investments_pots SET status = 'ARCHIVED' WHERE id = $1`, [archivedPot.id]);

  await assertThrowsHttp(
    "4a. a movement targeting an archived Pot is rejected",
    () =>
      executeReallocation(owner.id, [
        {
          accountAssetId: bb1.id.toString(),
          fromPotId: pot4.id.toString(),
          toPotId: archivedPot.id.toString(),
          units: "1",
        },
      ]),
    400,
    "archived"
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 5. Cross-user ownership checks.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n5. Cross-user ownership checks");

  await assertThrowsHttp(
    "5a. otherUser cannot reallocate between owner's Pots",
    () =>
      executeReallocation(other.id, [
        { accountAssetId: bb1.id.toString(), fromPotId: pot4.id.toString(), toPotId: pot5.id.toString(), units: "1" },
      ]),
    404,
    "Pots not found"
  );

  const otherPotFrom = await potRepo.insertPot(pool, other.id, "OtherUserPotFrom", null, "savings");
  const otherPotTo = await potRepo.insertPot(pool, other.id, "OtherUserPotTo", null, "savings");
  await assertThrowsHttp(
    "5b. otherUser cannot move owner's asset even between two of otherUser's OWN Pots " +
      "(account-asset ownership check catches it, independent of the Pot-ownership check)",
    () =>
      executeReallocation(other.id, [
        {
          accountAssetId: bb1.id.toString(),
          fromPotId: otherPotFrom.id.toString(),
          toPotId: otherPotTo.id.toString(),
          units: "1",
        },
      ]),
    404,
    "assets not found"
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 6. Priceless-asset exclusion from getReallocationData.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n6. Priceless-asset exclusion");

  const assetNoPrice = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: ISIN_NOPRICE,
    name: "Reallocation Test Asset (No Price)",
    symbol: null,
    assetClass: "STOCK",
    amfiSchemeCode: null,
  });
  const noPriceAccountAsset = await assetRepo.findOrCreateAccountAsset(pool, owner.id, account.id, assetNoPrice.id);
  await positionRepo.adjustPotPosition(pool, owner.id, pot1.id, noPriceAccountAsset.id, "10");
  // Deliberately never call priceRepo.upsertLatestPrice for this asset.

  const dataWithNoPriceAsset = await getReallocationData(owner.id);
  const pot1WithNoPriceAsset = dataWithNoPriceAsset.pots.find((p) => p.id === pot1.id.toString());
  const noPriceEntry = pot1WithNoPriceAsset?.positions.find(
    (p) => p.accountAssetId === noPriceAccountAsset.id.toString()
  );
  assertEqual(
    "6a. an asset with no cached latest price is excluded from the Pot's position breakdown entirely",
    noPriceEntry,
    undefined
  );

  // ── Summary ────────────────────────────────────────────────────────────
  console.log(`\n\u2500\u2500 ${pass} passed, ${fail} failed \u2500\u2500\n`);
}

main()
  .catch((e) => {
    fail++;
    console.error("\nUNEXPECTED ERROR:", e);
  })
  .finally(async () => {
    await cleanup([OWNER_EMAIL, OTHER_EMAIL], [ISIN_A1, ISIN_A2, ISIN_B1, ISIN_B2, ISIN_NOPRICE]);
    await pool.end();
    process.exit(fail > 0 ? 1 : 0);
  });
