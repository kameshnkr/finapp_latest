/**
 * TEST SCRIPT — Investments reconciliation math (pure, no DB, no network)
 *
 * Exercises reconcileAssetPositions() directly — see the doc-comment on that
 * function in investmentsReconciliationService.ts ("kept separate and
 * side-effect-free so it's directly unit-testable"). Covers every branch:
 *   - exact match (existing + buy - sell == holdings)               -> no mismatch
 *   - Holdings reports MORE than expected                            -> BUY dummy proposed
 *   - Holdings reports LESS than expected                            -> SELL dummy proposed
 *   - asset entirely missing from the Holdings file (null)           -> treated as 0 units
 *   - floating-point noise within the epsilon tolerance               -> no mismatch
 *   - no Holdings price available for the mismatched asset           -> canCreateDummy=false
 *   - multiple independent per-asset mismatches in one reconciliation call
 *
 * Usage:
 *   npx tsx src/scripts/investmentsReconciliationTest.ts
 */

import {
  reconcileAssetPositions,
  type ReconciliationInput,
} from "../services/investmentsReconciliationService.js";

let pass = 0;
let fail = 0;

function check(label: string, actual: unknown, expected: unknown): void {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    pass++;
    console.log(`  \u2713 ${label}`);
  } else {
    fail++;
    console.log(`  \u2717 ${label}`);
    console.log(`      expected: ${JSON.stringify(expected)}`);
    console.log(`      actual  : ${JSON.stringify(actual)}`);
  }
}

console.log("\n\u2500\u2500 Investments reconciliation math \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n");

// 1. Exact match — existing + buy - sell == holdings -> no mismatch at all.
{
  const input: ReconciliationInput = {
    accountAssetId: "1",
    isin: "INFTEST00011",
    assetName: "Test Fund A",
    existingUnits: 100,
    buyUnits: 50,
    sellUnits: 0,
    holdingsUnits: 150,
    holdingsPrice: 45.5,
  };
  check("1. exact match \u2192 no mismatch", reconcileAssetPositions([input]), []);
}

// 2. Holdings HIGHER than expected -> a BUY dummy is proposed for the delta.
{
  const input: ReconciliationInput = {
    accountAssetId: "2",
    isin: "INFTEST00022",
    assetName: "Test Fund B",
    existingUnits: 100,
    buyUnits: 50,
    sellUnits: 0,
    holdingsUnits: 160, // expected 150, +10 over
    holdingsPrice: 20,
  };
  const [m] = reconcileAssetPositions([input]);
  check("2. BUY-side mismatch: dummyType", m?.dummyType, "BUY");
  check("2. BUY-side mismatch: dummyUnits", m?.dummyUnits, "10.000000");
  check("2. BUY-side mismatch: dummyPrice (from Holdings file)", m?.dummyPrice, "20.0000");
  check("2. BUY-side mismatch: canCreateDummy", m?.canCreateDummy, true);
  check("2. BUY-side mismatch: expectedUnits", m?.expectedUnits, "150.000000");
}

// 3. Holdings LOWER than expected -> a SELL dummy is proposed for the delta.
{
  const input: ReconciliationInput = {
    accountAssetId: "3",
    isin: "INFTEST00033",
    assetName: "Test Fund C",
    existingUnits: 100,
    buyUnits: 0,
    sellUnits: 20,
    holdingsUnits: 70, // expected 80, -10 under
    holdingsPrice: 30,
  };
  const [m] = reconcileAssetPositions([input]);
  check("3. SELL-side mismatch: dummyType", m?.dummyType, "SELL");
  check("3. SELL-side mismatch: dummyUnits", m?.dummyUnits, "10.000000");
  check("3. SELL-side mismatch: expectedUnits", m?.expectedUnits, "80.000000");
}

// 4. Asset entirely missing from the Holdings file (null) -> treated as 0,
//    not skipped — the whole expected position is proposed as a SELL dummy.
{
  const input: ReconciliationInput = {
    accountAssetId: "4",
    isin: "INFTEST00044",
    assetName: "Test Fund D",
    existingUnits: 100,
    buyUnits: 0,
    sellUnits: 0,
    holdingsUnits: null,
    holdingsPrice: null, // never reported anywhere for this asset
  };
  const [m] = reconcileAssetPositions([input]);
  check("4. missing-from-Holdings: dummyType", m?.dummyType, "SELL");
  check("4. missing-from-Holdings: dummyUnits", m?.dummyUnits, "100.000000");
  check("4. missing-from-Holdings: holdingsUnits normalized to 0", m?.holdingsUnits, "0.000000");
  check("4. missing-from-Holdings: canCreateDummy is false (no price anywhere)", m?.canCreateDummy, false);
  check("4. missing-from-Holdings: dummyPrice is null", m?.dummyPrice, null);
}

// 5. Float noise within the epsilon tolerance -> still no mismatch.
{
  const input: ReconciliationInput = {
    accountAssetId: "5",
    isin: "INFTEST00055",
    assetName: "Test Fund E",
    existingUnits: 100,
    buyUnits: 0,
    sellUnits: 0,
    holdingsUnits: 100.0001, // within UNITS_EPSILON (0.001)
    holdingsPrice: 10,
  };
  check("5. within-epsilon noise \u2192 no mismatch", reconcileAssetPositions([input]), []);
}

// 6. Multiple independent assets in one reconciliation call — only the
//    genuinely mismatched ones should be reported, each independently.
{
  const inputs: ReconciliationInput[] = [
    {
      accountAssetId: "6a",
      isin: "INFTEST00066",
      assetName: "Test Fund F (matches)",
      existingUnits: 10,
      buyUnits: 0,
      sellUnits: 0,
      holdingsUnits: 10,
      holdingsPrice: 5,
    },
    {
      accountAssetId: "6b",
      isin: "INFTEST00077",
      assetName: "Test Fund G (mismatches)",
      existingUnits: 10,
      buyUnits: 0,
      sellUnits: 0,
      holdingsUnits: 15,
      holdingsPrice: 5,
    },
  ];
  const mismatches = reconcileAssetPositions(inputs);
  check("6. only the genuinely-mismatched asset is reported", mismatches.length, 1);
  check("6. the reported mismatch is the right asset", mismatches[0]?.accountAssetId, "6b");
}

console.log(`\n\u2500\u2500 ${pass} passed, ${fail} failed \u2500\u2500\n`);
if (fail > 0) process.exit(1);
