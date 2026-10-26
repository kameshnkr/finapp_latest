/**
 * TEST SCRIPT — Banking Budget funds reallocation (bankingReallocationService)
 * against the REAL database.
 *
 * Mirrors investmentsReallocationTest.ts's structure exactly (Budget ≈ Pot,
 * Account ≈ account-asset): a "reduce" scenario, an "increase" scenario,
 * the insufficient-funds guard (single + aggregate-across-movements), a
 * same-budget rejection, cross-user ownership checks (Budget + Account),
 * and the zero-allocation exclusion rule from getReallocationData.
 *
 * Uses the real repositories/services (never raw ad-hoc SQL for the
 * assertions themselves — only for the final cleanup), with a temporary
 * test user + a cross-user test user created fresh and fully deleted again
 * at the end (or on failure — cleanup runs in a `finally`), so this is safe
 * to re-run any number of times.
 *
 * Usage:
 *   npx tsx src/scripts/bankingReallocationTest.ts
 */

import { pool } from "../db/pool.js";
import * as userRepo from "../repositories/userRepository.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import {
  getReallocationData,
  executeReallocation,
  REALLOCATION_INSUFFICIENT_FUNDS_MESSAGE,
  type ReallocationMovementInput,
} from "../services/bankingReallocationService.js";
import { HttpError } from "../utils/errors.js";

const RUN_TAG = Date.now().toString(36);
const OWNER_EMAIL = `bankingtest_realloc_owner_${RUN_TAG}@phase9.test`;
const OTHER_EMAIL = `bankingtest_realloc_other_${RUN_TAG}@phase9.test`;

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

async function cleanup(emails: string[]): Promise<void> {
  await pool.query(`DELETE FROM users WHERE email = ANY($1::text[])`, [emails]);
}

async function main(): Promise<void> {
  await cleanup([OWNER_EMAIL, OTHER_EMAIL]);

  console.log("\n\u2500\u2500 Banking Budget reallocation (live DB) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n");

  const owner = await userRepo.createUser(pool, OWNER_EMAIL);
  const other = await userRepo.createUser(pool, OTHER_EMAIL);

  const account1 = await accountRepo.insertAccount(pool, owner.id, "Test Account 1", "0");
  const account2 = await accountRepo.insertAccount(pool, owner.id, "Test Account 2", "0");

  // ═══════════════════════════════════════════════════════════════════════
  // 1. "Reduce" scenario — exactly mirrors investmentsReallocationTest.ts's
  //    first worked example: Budget1 (100rs: Account1 60, Account2 40)
  //    reduced to 80rs, 10rs each sent to Budget2 and Budget3 (both
  //    starting at 0rs).
  // ═══════════════════════════════════════════════════════════════════════
  console.log("1. Reduce scenario (Budget1 100rs -> 80rs, split 10rs/10rs to Budget2/Budget3)");

  const budget1 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget1", "manual", null, null, null);
  const budget2 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget2", "manual", null, null, null);
  const budget3 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget3", "manual", null, null, null);

  await allocationRepo.upsertAllocation(pool, account1.id, budget1.id, "60.00");
  await allocationRepo.upsertAllocation(pool, account2.id, budget1.id, "40.00");

  const dataBefore = await getReallocationData(owner.id);
  const budget1Before = dataBefore.budgets.find((b) => b.id === budget1.id.toString());
  const budget2Before = dataBefore.budgets.find((b) => b.id === budget2.id.toString());
  assertEqual("1a. getReallocationData: Budget1 fundsAvailable = 100.00", budget1Before?.fundsAvailable, "100.00");
  assertEqual("1b. getReallocationData: Budget1 has 2 allocation entries", budget1Before?.allocations.length, 2);
  assertEqual(
    "1c. getReallocationData: Budget2 fundsAvailable = 0.00 (no allocations yet)",
    budget2Before?.fundsAvailable,
    "0.00"
  );

  const reduceMovements: ReallocationMovementInput[] = [
    { accountId: account1.id.toString(), fromBudgetId: budget1.id.toString(), toBudgetId: budget2.id.toString(), amount: "7.50" },
    { accountId: account1.id.toString(), fromBudgetId: budget1.id.toString(), toBudgetId: budget3.id.toString(), amount: "7.50" },
    { accountId: account2.id.toString(), fromBudgetId: budget1.id.toString(), toBudgetId: budget2.id.toString(), amount: "2.50" },
    { accountId: account2.id.toString(), fromBudgetId: budget1.id.toString(), toBudgetId: budget3.id.toString(), amount: "2.50" },
  ];
  const reduceResult = await executeReallocation(owner.id, reduceMovements);
  assertEqual("1d. executeReallocation: movedCount", reduceResult.movedCount, 4);

  assertClose(
    "1e. Budget1/Account1 allocation: 60.0 -> 45.0",
    await allocationRepo.getAllocationAmount(pool, account1.id, budget1.id),
    45.0
  );
  assertClose(
    "1f. Budget1/Account2 allocation: 40.0 -> 35.0",
    await allocationRepo.getAllocationAmount(pool, account2.id, budget1.id),
    35.0
  );
  assertClose(
    "1g. Budget2/Account1 allocation: 0 -> 7.5",
    await allocationRepo.getAllocationAmount(pool, account1.id, budget2.id),
    7.5
  );
  assertClose(
    "1h. Budget3/Account1 allocation: 0 -> 7.5",
    await allocationRepo.getAllocationAmount(pool, account1.id, budget3.id),
    7.5
  );
  assertClose(
    "1i. Budget2/Account2 allocation: 0 -> 2.5",
    await allocationRepo.getAllocationAmount(pool, account2.id, budget2.id),
    2.5
  );
  assertClose(
    "1j. Budget3/Account2 allocation: 0 -> 2.5",
    await allocationRepo.getAllocationAmount(pool, account2.id, budget3.id),
    2.5
  );

  const dataAfterReduce = await getReallocationData(owner.id);
  const budget1AfterReduce = dataAfterReduce.budgets.find((b) => b.id === budget1.id.toString());
  const budget2AfterReduce = dataAfterReduce.budgets.find((b) => b.id === budget2.id.toString());
  const budget3AfterReduce = dataAfterReduce.budgets.find((b) => b.id === budget3.id.toString());
  assertEqual("1k. Budget1 fundsAvailable after reduce = 80.00", budget1AfterReduce?.fundsAvailable, "80.00");
  assertEqual("1l. Budget2 fundsAvailable after reduce = 10.00", budget2AfterReduce?.fundsAvailable, "10.00");
  assertEqual("1m. Budget3 fundsAvailable after reduce = 10.00", budget3AfterReduce?.fundsAvailable, "10.00");

  // ═══════════════════════════════════════════════════════════════════════
  // 2. "Increase" scenario — mirrors investmentsReallocationTest.ts's second
  //    worked example, using a fresh set of Budgets so it's independent of
  //    section 1's resulting state.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n2. Increase scenario (Budget5 200rs -> 250rs, 25rs/25rs pulled from Budget4/Budget6)");

  const budget4 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget4", "manual", null, null, null);
  const budget5 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget5", "manual", null, null, null);
  const budget6 = await budgetRepo.insertBudget(pool, owner.id, "TestBudget6", "manual", null, null, null);

  // Budget4: 30+70=100rs. Budget5: 80+120=200rs. Budget6: 100+200=300rs.
  await allocationRepo.upsertAllocation(pool, account1.id, budget4.id, "30.00");
  await allocationRepo.upsertAllocation(pool, account2.id, budget4.id, "70.00");
  await allocationRepo.upsertAllocation(pool, account1.id, budget5.id, "80.00");
  await allocationRepo.upsertAllocation(pool, account2.id, budget5.id, "120.00");
  await allocationRepo.upsertAllocation(pool, account1.id, budget6.id, "100.00");
  await allocationRepo.upsertAllocation(pool, account2.id, budget6.id, "200.00");

  const dataBeforeIncrease = await getReallocationData(owner.id);
  const budget5Before = dataBeforeIncrease.budgets.find((b) => b.id === budget5.id.toString());
  assertEqual("2a. getReallocationData: Budget5 fundsAvailable = 200.00", budget5Before?.fundsAvailable, "200.00");
  const budget6Before = dataBeforeIncrease.budgets.find((b) => b.id === budget6.id.toString());
  assertEqual("2b. getReallocationData: Budget6 fundsAvailable = 300.00", budget6Before?.fundsAvailable, "300.00");

  const increaseMovements: ReallocationMovementInput[] = [
    { accountId: account1.id.toString(), fromBudgetId: budget4.id.toString(), toBudgetId: budget5.id.toString(), amount: "12.50" },
    { accountId: account1.id.toString(), fromBudgetId: budget6.id.toString(), toBudgetId: budget5.id.toString(), amount: "12.50" },
    { accountId: account2.id.toString(), fromBudgetId: budget4.id.toString(), toBudgetId: budget5.id.toString(), amount: "12.50" },
    { accountId: account2.id.toString(), fromBudgetId: budget6.id.toString(), toBudgetId: budget5.id.toString(), amount: "12.50" },
  ];
  const increaseResult = await executeReallocation(owner.id, increaseMovements);
  assertEqual("2c. executeReallocation: movedCount", increaseResult.movedCount, 4);

  const dataAfterIncrease = await getReallocationData(owner.id);
  const budget4After = dataAfterIncrease.budgets.find((b) => b.id === budget4.id.toString());
  const budget5After = dataAfterIncrease.budgets.find((b) => b.id === budget5.id.toString());
  const budget6After = dataAfterIncrease.budgets.find((b) => b.id === budget6.id.toString());
  assertEqual("2d. Budget4 fundsAvailable after increase = 75.00 (lost 25rs)", budget4After?.fundsAvailable, "75.00");
  assertEqual(
    "2e. Budget5 fundsAvailable after increase = 250.00 (target hit exactly)",
    budget5After?.fundsAvailable,
    "250.00"
  );
  assertEqual("2f. Budget6 fundsAvailable after increase = 275.00 (lost 25rs)", budget6After?.fundsAvailable, "275.00");

  assertClose(
    "2g. Total Account1 allocation across Budget4+5+6 unchanged at 210.0 (30+80+100)",
    (await allocationRepo.getAllocationAmount(pool, account1.id, budget4.id)) +
      (await allocationRepo.getAllocationAmount(pool, account1.id, budget5.id)) +
      (await allocationRepo.getAllocationAmount(pool, account1.id, budget6.id)),
    210.0
  );
  assertClose(
    "2h. Total Account2 allocation across Budget4+5+6 unchanged at 390.0 (70+120+200)",
    (await allocationRepo.getAllocationAmount(pool, account2.id, budget4.id)) +
      (await allocationRepo.getAllocationAmount(pool, account2.id, budget5.id)) +
      (await allocationRepo.getAllocationAmount(pool, account2.id, budget6.id)),
    390.0
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 3. Insufficient-funds guard — must reject atomically (no partial write)
  //    when a movement would drive a source account's allocation negative.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n3. Insufficient-funds guard");

  const budget4Acc1Before = await allocationRepo.getAllocationAmount(pool, account1.id, budget4.id);
  await assertThrowsHttp(
    "3a. a movement exceeding the source account's allocation is rejected with the exact spec message",
    () =>
      executeReallocation(owner.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget5.id.toString(),
          amount: "9999.00",
        },
      ]),
    400,
    REALLOCATION_INSUFFICIENT_FUNDS_MESSAGE
  );
  assertClose(
    "3b. rejected movement leaves the source account's allocation completely unchanged",
    await allocationRepo.getAllocationAmount(pool, account1.id, budget4.id),
    budget4Acc1Before
  );

  // 3c. Aggregate-across-movements check: two movements pulling the same
  // account's allocation from the same Budget, each individually fine but
  // not together.
  await assertThrowsHttp(
    "3c. two movements that are fine individually but not in aggregate are rejected",
    () =>
      executeReallocation(owner.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget5.id.toString(),
          amount: (budget4Acc1Before * 0.7).toFixed(2),
        },
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget6.id.toString(),
          amount: (budget4Acc1Before * 0.7).toFixed(2),
        },
      ]),
    400,
    REALLOCATION_INSUFFICIENT_FUNDS_MESSAGE
  );
  assertClose(
    "3d. rejected aggregate movement leaves the source account's allocation completely unchanged",
    await allocationRepo.getAllocationAmount(pool, account1.id, budget4.id),
    budget4Acc1Before
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 4. Same-Budget + malformed-input guards.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n4. Same-Budget + malformed-input guards");

  await assertThrowsHttp(
    "4a. a movement with identical from/to Budget is rejected",
    () =>
      executeReallocation(owner.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget4.id.toString(),
          amount: "1.00",
        },
      ]),
    400,
    "must be different"
  );

  await assertThrowsHttp(
    "4b. a zero-amount movement is rejected",
    () =>
      executeReallocation(owner.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget5.id.toString(),
          amount: "0",
        },
      ]),
    400,
    "positive"
  );

  await assertThrowsHttp("4c. no movements at all is rejected", () => executeReallocation(owner.id, []), 400);

  // ═══════════════════════════════════════════════════════════════════════
  // 5. Cross-user ownership checks.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n5. Cross-user ownership checks");

  await assertThrowsHttp(
    "5a. otherUser cannot reallocate between owner's Budgets",
    () =>
      executeReallocation(other.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: budget4.id.toString(),
          toBudgetId: budget5.id.toString(),
          amount: "1.00",
        },
      ]),
    404,
    "Budgets not found"
  );

  const otherBudgetFrom = await budgetRepo.insertBudget(pool, other.id, "OtherUserBudgetFrom", "manual", null, null, null);
  const otherBudgetTo = await budgetRepo.insertBudget(pool, other.id, "OtherUserBudgetTo", "manual", null, null, null);
  await assertThrowsHttp(
    "5b. otherUser cannot move owner's account even between two of otherUser's OWN Budgets " +
      "(account ownership check catches it, independent of the Budget-ownership check)",
    () =>
      executeReallocation(other.id, [
        {
          accountId: account1.id.toString(),
          fromBudgetId: otherBudgetFrom.id.toString(),
          toBudgetId: otherBudgetTo.id.toString(),
          amount: "1.00",
        },
      ]),
    404,
    "accounts not found"
  );

  // ═══════════════════════════════════════════════════════════════════════
  // 6. Zero-allocation exclusion from getReallocationData's breakdown.
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n6. Zero-allocation exclusion from breakdown");

  const account3 = await accountRepo.insertAccount(pool, owner.id, "Test Account 3 (zero alloc)", "0");
  await allocationRepo.upsertAllocation(pool, account3.id, budget4.id, "0.00");

  const dataWithZeroAlloc = await getReallocationData(owner.id);
  const budget4WithZero = dataWithZeroAlloc.budgets.find((b) => b.id === budget4.id.toString());
  const zeroEntry = budget4WithZero?.allocations.find((a) => a.accountId === account3.id.toString());
  assertEqual(
    "6a. a zero-amount allocation is excluded from the Budget's breakdown entirely",
    zeroEntry,
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
    await cleanup([OWNER_EMAIL, OTHER_EMAIL]);
    await pool.end();
    process.exit(fail > 0 ? 1 : 0);
  });
