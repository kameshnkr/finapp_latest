/**
 * TEST SCRIPT — Investments core backend logic (allocation math, the SELL
 * negative-guard, dedup/fingerprint collisions, cross-user ownership
 * checks, and current-value computation) against the REAL database.
 *
 * Runs entirely through the real repositories/services (never raw ad-hoc
 * SQL for the assertions themselves), using two temporary test users that
 * are created fresh and fully deleted again at the end (or on failure —
 * cleanup runs in a `finally`), so this is safe to re-run any number of
 * times without leaving residue. It also cleans up any leftover rows from
 * a previous run that crashed before its own cleanup, at the very start.
 *
 * Deliberately bypasses the LLM-parsing/Excel-upload pipeline entirely
 * (already covered live in Phase 2's end-to-end upload test) — trades are
 * inserted directly via investmentsTransactionRepository so the math here
 * is deterministic and has zero external dependencies (no network, no
 * LLM API key required).
 *
 * Usage:
 *   npx tsx src/scripts/investmentsCoreLogicTest.ts
 */

import { pool } from "../db/pool.js";
import * as userRepo from "../repositories/userRepository.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import * as assetRepo from "../repositories/investmentsAssetRepository.js";
import * as potRepo from "../repositories/investmentsPotRepository.js";
import * as positionRepo from "../repositories/investmentsPositionRepository.js";
import * as priceRepo from "../repositories/investmentsPriceRepository.js";
import * as txRepo from "../repositories/investmentsTransactionRepository.js";
import { computeInvestmentsFingerprint } from "../utils/investmentsFingerprint.js";
import { allocateTransactions, SELL_INSUFFICIENT_UNITS_MESSAGE } from "../services/investmentsAllocationService.js";
import { getAssetsGroupedByAccount, getPotsOverview } from "../services/investmentsPortfolioService.js";
import { listAccounts } from "../services/investmentsAccountService.js";
import { HttpError } from "../utils/errors.js";

const RUN_TAG = Date.now().toString(36);
const OWNER_EMAIL = `investmentstest_owner_${RUN_TAG}@phase8.test`;
const OTHER_EMAIL = `investmentstest_other_${RUN_TAG}@phase8.test`;
const BOOTSTRAP_RACE_EMAIL = `investmentstest_bootstrap_${RUN_TAG}@phase8.test`;
const TEST_ISIN = `INFTESTCORE${RUN_TAG}`.slice(0, 20).toUpperCase();

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

/** Deletes both test users (cascades every user-scoped row) and the global
 * test asset row this run created (assets aren't user-scoped, so cascading
 * from the users alone wouldn't remove it). Safe to call even if some rows
 * were never created (idempotent DELETEs). */
async function cleanup(emails: string[], isin: string): Promise<void> {
  await pool.query(`DELETE FROM users WHERE email = ANY($1::text[])`, [emails]);
  await pool.query(`DELETE FROM investments_assets WHERE isin = $1`, [isin]);
}

async function main(): Promise<void> {
  // Defensive pre-clean in case a previous crashed run left residue under
  // the same tag pattern (won't collide with a real run's own RUN_TAG, but
  // guards against manual re-runs of a fixed tag during debugging).
  await cleanup([OWNER_EMAIL, OTHER_EMAIL, BOOTSTRAP_RACE_EMAIL], TEST_ISIN);

  console.log("\n\u2500\u2500 Investments core backend logic (live DB) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n");

  const owner = await userRepo.createUser(pool, OWNER_EMAIL);
  const other = await userRepo.createUser(pool, OTHER_EMAIL);

  // ── Fixtures ─────────────────────────────────────────────────────────────
  // Create the owner's Pots/Account BEFORE any call that could trigger
  // ensureDefaultInvestmentsDataForUser's lazy bootstrap (getPotsOverview /
  // getAssetsGroupedByAccount) — that bootstrap only fills in whichever of
  // Pots/Accounts is currently empty, so seeding both ourselves first means
  // no default rows are ever created to interfere with this test's numbers.
  const potA = await potRepo.insertPot(pool, owner.id, "TestPotA", null);
  const potB = await potRepo.insertPot(pool, owner.id, "TestPotB", null);
  const ownerAccount = await accountRepo.insertAccount(pool, owner.id, "Test Account", null);

  const asset = await assetRepo.findOrCreateAssetByIsin(pool, {
    isin: TEST_ISIN,
    name: "Investments Core Logic Test Fund",
    symbol: null,
    assetClass: "MUTUAL_FUND",
    amfiSchemeCode: null,
  });
  const ownerAccountAsset = await assetRepo.findOrCreateAccountAsset(pool, owner.id, ownerAccount.id, asset.id);

  // ═══════════════════════════════════════════════════════════════════════
  // 1. Current-value computation: units x latest price, at both the Asset
  //    and Total-Portfolio-Value level.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("1. Current-value computation");

  await positionRepo.adjustPosition(pool, owner.id, ownerAccountAsset.id, "100");
  await priceRepo.upsertLatestPrice(pool, asset.id, "25.5000", "2026-01-01", "TEST_SOURCE");

  const assetsByAccount = await getAssetsGroupedByAccount(owner.id);
  const account = assetsByAccount.find((a) => a.accountId === ownerAccount.id.toString());
  const assetEntry = account?.assets.find((a) => a.accountAssetId === ownerAccountAsset.id.toString());
  assertEqual("1a. asset currentValue = units(100) x price(25.50)", assetEntry?.currentValue, "2550.00");

  const portfolio = await getPotsOverview(owner.id);
  assertEqual(
    "1b. totalPortfolioValue reflects the same position (fresh test user, single position)",
    portfolio.totalPortfolioValue,
    "2550.00"
  );
  const potAOverview = portfolio.pots.find((p) => p.id === potA.id.toString());
  assertEqual("1c. Pot current value is 0 before any allocation exists", potAOverview?.currentValue, "0.00");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. Allocation math — all 3 supported flows, tracked against a running
  //    expected ledger per Pot (computed independently of the service under
  //    test, so this genuinely checks the service's arithmetic).
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n2. Allocation math (single/multi trade x single/multi Pot)");

  let expectedPotAUnits = 0;
  let expectedPotBUnits = 0;
  let nextTradeDay = 1;

  async function insertBuyTrade(units: number, price: number): Promise<bigint> {
    const day = String(nextTradeDay++).padStart(2, "0");
    const date = `2026-02-${day}`;
    const fingerprint = computeInvestmentsFingerprint({
      accountId: ownerAccount.id,
      isin: TEST_ISIN,
      transactionType: "BUY",
      units: units.toFixed(6),
      price: price.toFixed(4),
      transactionDate: date,
    });
    const [row] = await txRepo.insertTransactions(pool, owner.id, [
      {
        accountAssetId: ownerAccountAsset.id,
        transactionType: "BUY",
        units: units.toFixed(6),
        price: price.toFixed(4),
        amount: (units * price).toFixed(2),
        transactionDate: date,
        sourceReferenceId: null,
        fingerprint,
      },
    ]);
    return row!.id;
  }

  async function insertSellTrade(units: number, price: number): Promise<bigint> {
    const day = String(nextTradeDay++).padStart(2, "0");
    const date = `2026-02-${day}`;
    const fingerprint = computeInvestmentsFingerprint({
      accountId: ownerAccount.id,
      isin: TEST_ISIN,
      transactionType: "SELL",
      units: units.toFixed(6),
      price: price.toFixed(4),
      transactionDate: date,
    });
    const [row] = await txRepo.insertTransactions(pool, owner.id, [
      {
        accountAssetId: ownerAccountAsset.id,
        transactionType: "SELL",
        units: units.toFixed(6),
        price: price.toFixed(4),
        amount: (units * price).toFixed(2),
        transactionDate: date,
        sourceReferenceId: null,
        fingerprint,
      },
    ]);
    return row!.id;
  }

  // 2a. Single trade -> single Pot (100%).
  const trade1 = await insertBuyTrade(40, 25.5);
  const r1 = await allocateTransactions(owner.id, [trade1], [{ potId: potA.id.toString(), percentage: 100 }]);
  expectedPotAUnits += 40;
  assertEqual("2a. single trade \u2192 single Pot: allocatedCount", r1.allocatedCount, 1);
  assertClose(
    "2a. Pot A position after single-trade allocation",
    await positionRepo.getPotPositionUnits(pool, owner.id, potA.id, ownerAccountAsset.id),
    expectedPotAUnits
  );

  // 2b. Single trade -> multiple Pots (60% / 40%).
  const trade2 = await insertBuyTrade(60, 25.5);
  const r2 = await allocateTransactions(
    owner.id,
    [trade2],
    [
      { potId: potA.id.toString(), percentage: 60 },
      { potId: potB.id.toString(), percentage: 40 },
    ]
  );
  expectedPotAUnits += 36; // 60% of 60
  expectedPotBUnits += 24; // 40% of 60
  assertEqual("2b. single trade \u2192 multiple Pots: allocatedCount", r2.allocatedCount, 1);
  assertClose(
    "2b. Pot A position after multi-Pot split",
    await positionRepo.getPotPositionUnits(pool, owner.id, potA.id, ownerAccountAsset.id),
    expectedPotAUnits
  );
  assertClose(
    "2b. Pot B position after multi-Pot split",
    await positionRepo.getPotPositionUnits(pool, owner.id, potB.id, ownerAccountAsset.id),
    expectedPotBUnits
  );

  // 2c. Multiple trades -> single Pot (100% each).
  const trade3 = await insertBuyTrade(10, 25.5);
  const trade4 = await insertBuyTrade(15, 25.5);
  const r3 = await allocateTransactions(owner.id, [trade3, trade4], [{ potId: potB.id.toString(), percentage: 100 }]);
  expectedPotBUnits += 25; // 10 + 15
  assertEqual("2c. multiple trades \u2192 single Pot: allocatedCount", r3.allocatedCount, 2);
  assertClose(
    "2c. Pot B position after multi-trade allocation",
    await positionRepo.getPotPositionUnits(pool, owner.id, potB.id, ownerAccountAsset.id),
    expectedPotBUnits
  );

  // 2d. Rejected: multiple trades -> multiple Pots in one request.
  const trade5 = await insertBuyTrade(5, 25.5);
  const trade6 = await insertBuyTrade(5, 25.5);
  await assertThrowsHttp(
    "2d. multiple trades \u2192 multiple Pots is rejected",
    () =>
      allocateTransactions(
        owner.id,
        [trade5, trade6],
        [
          { potId: potA.id.toString(), percentage: 50 },
          { potId: potB.id.toString(), percentage: 50 },
        ]
      ),
    400,
    "isn't supported"
  );

  // 2e. Rejected: percentages don't sum to 100.
  const trade7 = await insertBuyTrade(5, 25.5);
  await assertThrowsHttp(
    "2e. percentages not summing to 100 is rejected",
    () =>
      allocateTransactions(
        owner.id,
        [trade7],
        [
          { potId: potA.id.toString(), percentage: 50 },
          { potId: potB.id.toString(), percentage: 40 },
        ]
      ),
    400,
    "must sum to 100"
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 3. SELL insufficient-units guard — must reject atomically (no partial
  //    write) when a SELL would drive a Pot's position negative, and must
  //    succeed normally when the Pot holds enough.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n3. SELL insufficient-units guard");

  const potAUnitsBeforeBadSell = await positionRepo.getPotPositionUnits(pool, owner.id, potA.id, ownerAccountAsset.id);
  const bigSell = await insertSellTrade(1000, 25.5); // far more than Pot A holds
  await assertThrowsHttp(
    "3a. SELL exceeding a Pot's position is rejected with the exact spec message",
    () => allocateTransactions(owner.id, [bigSell], [{ potId: potA.id.toString(), percentage: 100 }]),
    400,
    SELL_INSUFFICIENT_UNITS_MESSAGE
  );
  const potAUnitsAfterBadSell = await positionRepo.getPotPositionUnits(pool, owner.id, potA.id, ownerAccountAsset.id);
  assertClose(
    "3b. rejected SELL leaves the Pot position completely unchanged (atomic rollback)",
    potAUnitsAfterBadSell,
    potAUnitsBeforeBadSell
  );
  const bigSellRow = await txRepo.getTransactionForUser(pool, owner.id, bigSell);
  assertEqual(
    "3c. rejected SELL trade itself remains UNALLOCATED (not partially marked)",
    bigSellRow?.allocation_status,
    "UNALLOCATED"
  );

  // 3d. A SELL that the Pot CAN cover succeeds and decrements the position.
  const okSell = await insertSellTrade(30, 25.5);
  const r4 = await allocateTransactions(owner.id, [okSell], [{ potId: potA.id.toString(), percentage: 100 }]);
  expectedPotAUnits -= 30;
  assertEqual("3d. sufficient-units SELL: allocatedCount", r4.allocatedCount, 1);
  assertClose(
    "3d. Pot A position decremented by the SELL's units",
    await positionRepo.getPotPositionUnits(pool, owner.id, potA.id, ownerAccountAsset.id),
    expectedPotAUnits
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 4. Dedup / fingerprint collisions
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n4. Dedup / fingerprint collisions");

  const dedupFingerprint = computeInvestmentsFingerprint({
    accountId: ownerAccount.id,
    isin: TEST_ISIN,
    transactionType: "BUY",
    units: "20.000000",
    price: "10.0000",
    transactionDate: "2026-03-01",
  });

  const beforeInsert = await txRepo.findExistingFingerprints(pool, owner.id, [dedupFingerprint]);
  assertEqual("4a. fingerprint not yet known before first insert", beforeInsert.size, 0);

  await txRepo.insertTransactions(pool, owner.id, [
    {
      accountAssetId: ownerAccountAsset.id,
      transactionType: "BUY",
      units: "20.000000",
      price: "10.0000",
      amount: "200.00",
      transactionDate: "2026-03-01",
      sourceReferenceId: null,
      fingerprint: dedupFingerprint,
    },
  ]);

  const afterInsert = await txRepo.findExistingFingerprints(pool, owner.id, [dedupFingerprint]);
  assertEqual(
    "4b. app-layer dedup check (findExistingFingerprints) detects it after insert " +
      "\u2014 this is exactly what the real upload pipeline uses to skip already-imported rows",
    afterInsert.has(dedupFingerprint),
    true
  );

  // 4c. DB-level backstop: a raw duplicate insert (same user + fingerprint)
  // must be rejected by the unique index, even if the app-layer check above
  // were somehow bypassed.
  try {
    await txRepo.insertTransactions(pool, owner.id, [
      {
        accountAssetId: ownerAccountAsset.id,
        transactionType: "BUY",
        units: "20.000000",
        price: "10.0000",
        amount: "200.00",
        transactionDate: "2026-03-01",
        sourceReferenceId: null,
        fingerprint: dedupFingerprint,
      },
    ]);
    bad("4c. DB-level unique index rejects a raw duplicate-fingerprint insert", "insert unexpectedly succeeded");
  } catch (e) {
    const code = (e as { code?: string } | null)?.code;
    if (code === "23505") {
      ok("4c. DB-level unique index rejects a raw duplicate-fingerprint insert");
    } else {
      bad("4c. DB-level unique index rejects a raw duplicate-fingerprint insert", `unexpected error: ${e}`);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 5. Cross-user ownership checks
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n5. Cross-user ownership checks");

  await assertThrowsHttp(
    "5a. otherUser cannot allocate a trade that belongs to owner",
    () => allocateTransactions(other.id, [trade7], [{ potId: potA.id.toString(), percentage: 100 }]),
    404,
    "trades not found"
  );

  const otherAccount = await accountRepo.insertAccount(pool, other.id, "Other User Account", null);
  const otherAccountAsset = await assetRepo.findOrCreateAccountAsset(pool, other.id, otherAccount.id, asset.id);
  const otherFingerprint = computeInvestmentsFingerprint({
    accountId: otherAccount.id,
    isin: TEST_ISIN,
    transactionType: "BUY",
    units: "5.000000",
    price: "10.0000",
    transactionDate: "2026-03-02",
  });
  const [otherTradeRow] = await txRepo.insertTransactions(pool, other.id, [
    {
      accountAssetId: otherAccountAsset.id,
      transactionType: "BUY",
      units: "5.000000",
      price: "10.0000",
      amount: "50.00",
      transactionDate: "2026-03-02",
      sourceReferenceId: null,
      fingerprint: otherFingerprint,
    },
  ]);

  await assertThrowsHttp(
    "5b. otherUser cannot allocate their OWN trade to owner's Pot",
    () => allocateTransactions(other.id, [otherTradeRow!.id], [{ potId: potA.id.toString(), percentage: 100 }]),
    404,
    "Pots not found"
  );

  const crossUserRead = await txRepo.getTransactionForUser(pool, other.id, trade7);
  assertEqual("5c. repo-level read isolation: otherUser can't read owner's trade by id", crossUserRead, null);

  // ═══════════════════════════════════════════════════════════════════════
  // 6. Concurrent default-data bootstrap for a brand-new user — regression
  //    test for a real race that surfaced in manual testing: the Home tab
  //    fires 3 parallel first-load requests (Pots / Accounts / Assets),
  //    each independently calling ensureDefaultInvestmentsDataForUser. All
  //    3 could pass the "does this user have any Pots yet?" check before
  //    any of them committed, so all 3 tried to insert the same default
  //    Pots, and the losers hit a raw 23505 unique-violation instead of a
  //    clean no-op. Fixed via ON CONFLICT DO NOTHING in the seeding inserts
  //    (see insertPotIfNotExists/insertAccountIfNotExists) — this exercises
  //    the exact same 3-way concurrency for a fresh user and asserts no
  //    error is thrown and no duplicate rows are created.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n6. Concurrent default-data bootstrap (brand-new user, 3 parallel first-load calls)");

  const bootstrapUser = await userRepo.createUser(pool, BOOTSTRAP_RACE_EMAIL);
  try {
    const [potsResult, accountsResult, assetsResult] = await Promise.all([
      getPotsOverview(bootstrapUser.id),
      listAccounts(bootstrapUser.id),
      getAssetsGroupedByAccount(bootstrapUser.id),
    ]);
    ok("6a. all 3 concurrent first-load calls resolve without throwing");
    assertEqual("6b. exactly 4 default Pots created (no duplicates from the race)", potsResult.pots.length, 4);
    assertEqual("6c. exactly 2 default Accounts created (no duplicates from the race)", accountsResult.length, 2);
    assertEqual(
      "6d. Assets-grouped-by-Account also sees exactly 2 accounts",
      assetsResult.length,
      2
    );
  } catch (e) {
    bad("6a. all 3 concurrent first-load calls resolve without throwing", `threw: ${e}`);
  }

  // ── Summary ────────────────────────────────────────────────────────────
  console.log(`\n\u2500\u2500 ${pass} passed, ${fail} failed \u2500\u2500\n`);
}

main()
  .catch((e) => {
    fail++;
    console.error("\nUNEXPECTED ERROR:", e);
  })
  .finally(async () => {
    await cleanup([OWNER_EMAIL, OTHER_EMAIL, BOOTSTRAP_RACE_EMAIL], TEST_ISIN);
    await pool.end();
    process.exit(fail > 0 ? 1 : 0);
  });
