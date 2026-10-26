import { pool } from "../db/pool.js";
import * as budgetRepo from "../repositories/budgetRepository.js";
import * as accountRepo from "../repositories/accountRepository.js";
import * as allocationRepo from "../repositories/allocationRepository.js";
import { HttpError } from "../utils/errors.js";

// account_budget_allocations.amount is NUMERIC(14,2) — same tolerance
// convention as investmentsReallocationService.ts's UNITS_EPSILON.
const AMOUNT_EPSILON = 0.005;

export const REALLOCATION_INSUFFICIENT_FUNDS_MESSAGE =
  "One of the source Budgets no longer has enough funds in that account to complete this reallocation. Please refresh and try again.";

function n(s: string | null | undefined): number {
  if (s === null || s === undefined) return 0;
  const v = parseFloat(s);
  return Number.isFinite(v) ? v : 0;
}

function money(v: number): string {
  return v.toFixed(2);
}

export type ReallocationAllocationEntry = {
  accountId: string;
  accountName: string;
  amount: string;
};

export type ReallocationBudgetEntry = {
  id: string;
  name: string;
  fundsAvailable: string;
  allocations: ReallocationAllocationEntry[];
};

/**
 * Data needed to build the "Reallocate Funds" guided UI entirely client-
 * side: every Budget's current funds-available total plus its full
 * per-account allocation breakdown. Mirrors
 * investmentsReallocationService.getReallocationData's shape exactly
 * (Budget ≈ Pot, Account ≈ account-asset) — see
 * backend/logics/banking_logics/banking_budget_funds_reallocation.log. The
 * client uses this to compute every default split/bound/cap locally — no
 * further round-trips needed until the final POST submits the fully
 * resolved movements.
 *
 * `fundsAvailable` is the SUM across ALL accounts (including zero/negative
 * ones, for parity with how it's displayed elsewhere), but `allocations`
 * (the Step-2 breakdown source list) excludes any account with a
 * zero-or-negative allocation to that Budget entirely — there's nothing to
 * move from it. In practice an allocation can't go negative (no UI path
 * produces one today), so this is purely a defensive filter, not a feature.
 */
export async function getReallocationData(userId: bigint): Promise<{ budgets: ReallocationBudgetEntry[] }> {
  const [budgets, accounts] = await Promise.all([
    budgetRepo.listBudgets(pool, userId),
    accountRepo.listAccounts(pool, userId),
  ]);
  if (budgets.length === 0) return { budgets: [] };

  const accountNameById = new Map(accounts.map((a) => [a.id.toString(), a.name]));
  const allocsByBudget = await allocationRepo.listAllocationsForBudgetsBatch(
    pool,
    budgets.map((b) => b.id)
  );

  return {
    budgets: budgets.map((b) => {
      const rows = allocsByBudget.get(b.id.toString()) ?? [];
      let fundsAvailable = 0;
      const allocations: ReallocationAllocationEntry[] = [];
      for (const row of rows) {
        const amt = n(row.amount);
        fundsAvailable += amt;
        if (amt <= AMOUNT_EPSILON) continue;
        allocations.push({
          accountId: row.account_id.toString(),
          accountName: accountNameById.get(row.account_id.toString()) ?? "Account",
          amount: money(amt),
        });
      }
      return {
        id: b.id.toString(),
        name: b.name,
        fundsAvailable: money(fundsAvailable),
        allocations,
      };
    }),
  };
}

export type ReallocationMovementInput = {
  accountId: string;
  fromBudgetId: string;
  toBudgetId: string;
  /** Decimal string, > 0 — the exact rupee amount to move for this one account/Budget pair. */
  amount: string;
};

type ParsedMovement = {
  accountId: bigint;
  fromBudgetId: bigint;
  toBudgetId: bigint;
  amount: string; // normalized to 2 decimals
};

/**
 * Validates and atomically applies a fully-resolved set of account-level
 * allocation movements between Budgets (already computed client-side by the
 * guided UI — this is the one place the server re-validates everything as
 * the source of truth).
 *
 * Deliberately a plain "-X here, +X there" direct adjustment of
 * account_budget_allocations for the SAME account — never touches the
 * account's total_balance (a reallocation only ever moves which Budget an
 * account's funds are attributed to, never real money). Mirrors
 * investmentsReallocationService.executeReallocation's safety pattern
 * exactly: a single pre-check of aggregated requested deductions per
 * (fromBudgetId, accountId) BEFORE any write, then every delta applied
 * inside one DB transaction — either the whole reallocation lands, or
 * nothing changes.
 *
 * Deliberately independent of budgetService.reallocateBetweenBudgets (the
 * existing greedy, largest-allocation-account-first transfer used by the
 * old `/api/budgets/reallocate` endpoint) — that function offers no user
 * control over which accounts fund the move, so it can't power this
 * explicit, user-picked-portions flow. Both coexist; this never touches
 * that code path, nor the per-account accountService.reallocateAllocation
 * flow powering the Accounts-tab sheet.
 */
export async function executeReallocation(
  userId: bigint,
  movements: ReallocationMovementInput[]
): Promise<{ movedCount: number }> {
  if (movements.length === 0) {
    throw new HttpError(400, "No movements specified");
  }

  const parsed: ParsedMovement[] = movements.map((m) => {
    const amount = parseFloat(m.amount);
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpError(400, "Each movement's amount must be a positive number");
    }
    let fromBudgetId: bigint, toBudgetId: bigint, accountId: bigint;
    try {
      fromBudgetId = BigInt(m.fromBudgetId);
      toBudgetId = BigInt(m.toBudgetId);
      accountId = BigInt(m.accountId);
    } catch {
      throw new HttpError(400, "Invalid budget or account id");
    }
    if (fromBudgetId === toBudgetId) {
      throw new HttpError(400, "A movement's source and target Budget must be different");
    }
    return { accountId, fromBudgetId, toBudgetId, amount: amount.toFixed(2) };
  });

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    // Every referenced Budget must belong to this user.
    const budgetIds = Array.from(
      new Set(parsed.flatMap((m) => [m.fromBudgetId, m.toBudgetId]).map(String))
    ).map(BigInt);
    for (const id of budgetIds) {
      const b = await budgetRepo.getBudgetForUser(client, userId, id);
      if (!b) throw new HttpError(404, "One or more Budgets not found");
    }

    // Every referenced account must belong to this user.
    const accountIds = Array.from(new Set(parsed.map((m) => m.accountId.toString()))).map(BigInt);
    for (const id of accountIds) {
      const a = await accountRepo.getAccountForUser(client, userId, id);
      if (!a) throw new HttpError(404, "One or more accounts not found");
    }

    // ── Mandatory sufficiency guard ── aggregate requested deduction per
    // (fromBudgetId, accountId) BEFORE writing anything, so a set of
    // movements that's fine individually but not in aggregate (e.g. 2
    // movements pulling the same account's allocation out of the same
    // Budget) is still caught before any partial write happens.
    //
    // Unlike investments_pot_positions (which has a DB-level
    // CHECK(units >= 0) backstop), account_budget_allocations has no such
    // constraint — this pre-check is the ONLY safeguard here, not a
    // belt-and-suspenders pair. Acceptable since a negative allocation
    // can't arise from any existing UI path today.
    const requestByKey = new Map<string, number>();
    for (const m of parsed) {
      const key = `${m.fromBudgetId}|${m.accountId}`;
      requestByKey.set(key, (requestByKey.get(key) ?? 0) + parseFloat(m.amount));
    }
    for (const [key, requestedAmount] of requestByKey) {
      const [budgetIdStr, accountIdStr] = key.split("|") as [string, string];
      const currentAmount = await allocationRepo.getAllocationAmount(
        client,
        BigInt(accountIdStr),
        BigInt(budgetIdStr)
      );
      if (requestedAmount > currentAmount + AMOUNT_EPSILON) {
        throw new HttpError(400, REALLOCATION_INSUFFICIENT_FUNDS_MESSAGE);
      }
    }

    // ── Commit: apply every delta — the giving account's allocation to
    // fromBudgetId shrinks, its allocation to toBudgetId grows by the same
    // amount. Never touches accounts.total_balance. ──
    for (const m of parsed) {
      await allocationRepo.adjustAllocation(client, m.accountId, m.fromBudgetId, `-${m.amount}`);
      await allocationRepo.adjustAllocation(client, m.accountId, m.toBudgetId, m.amount);
    }

    await client.query("COMMIT");
    return { movedCount: parsed.length };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}
