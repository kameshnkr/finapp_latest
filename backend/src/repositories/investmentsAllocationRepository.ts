import type { Pool, PoolClient } from "pg";
import { nextId } from "../utils/id.js";

type Db = Pool | PoolClient;

export type InvestmentsTransactionPotAllocationRow = {
  id: bigint;
  user_id: bigint;
  transaction_id: bigint;
  pot_id: bigint;
  allocation_method: string;
  allocation_value: string;
  allocated_units: string;
  version: number;
  created_at: Date;
};

/** Records one (transaction, pot) split. Called once per pot for a given
 * transaction — a single→multi-pot allocation calls this once per pot with
 * that pot's percentage/derived units. */
export async function insertAllocation(
  client: Db,
  userId: bigint,
  transactionId: bigint,
  potId: bigint,
  percentage: number,
  allocatedUnits: string
): Promise<InvestmentsTransactionPotAllocationRow> {
  const id = nextId();
  const r = await client.query<InvestmentsTransactionPotAllocationRow>(
    `INSERT INTO investments_transaction_pot_allocations
       (id, user_id, transaction_id, pot_id, allocation_method, allocation_value, allocated_units)
     VALUES ($1, $2, $3, $4, 'PERCENTAGE', $5::numeric, $6::numeric)
     RETURNING id, user_id, transaction_id, pot_id, allocation_method,
       allocation_value::text, allocated_units::text, version, created_at`,
    [id, userId, transactionId, potId, percentage, allocatedUnits]
  );
  return r.rows[0]!;
}

export type AllocationBreakdownRow = {
  transaction_id: bigint;
  pot_id: bigint;
  pot_name: string;
  allocation_value: string;
  allocated_units: string;
};

/** Pot allocation breakdown for a set of (already-labeled) transactions,
 * joined with Pot name for display — used by the Labeled trades list. */
export async function listAllocationsForTransactions(
  db: Db,
  transactionIds: bigint[]
): Promise<AllocationBreakdownRow[]> {
  if (transactionIds.length === 0) return [];
  const r = await db.query<AllocationBreakdownRow>(
    `SELECT tpa.transaction_id, tpa.pot_id, p.name AS pot_name,
            tpa.allocation_value::text, tpa.allocated_units::text
     FROM investments_transaction_pot_allocations tpa
     JOIN investments_pots p ON p.id = tpa.pot_id
     WHERE tpa.transaction_id = ANY($1::bigint[])
     ORDER BY tpa.created_at ASC`,
    [transactionIds]
  );
  return r.rows;
}
