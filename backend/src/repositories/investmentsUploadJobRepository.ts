import type { Pool, PoolClient } from "pg";
import type { InvestmentsUploadJobStatus } from "../types/investmentsDomain.js";

type Db = Pool | PoolClient;

export type InvestmentsUploadJobRow = {
  id: string;
  user_id: bigint;
  account_id: bigint;
  status: InvestmentsUploadJobStatus;
  stage_message: string | null;
  result: Record<string, unknown> | null;
  error_message: string | null;
  created_at: Date;
  updated_at: Date;
};

export async function createJob(
  db: Db,
  id: string,
  userId: bigint,
  accountId: bigint
): Promise<InvestmentsUploadJobRow> {
  const r = await db.query<InvestmentsUploadJobRow>(
    `INSERT INTO investments_upload_jobs (id, user_id, account_id, status, stage_message)
     VALUES ($1, $2, $3, 'UPLOADING', 'Uploading files...')
     RETURNING *`,
    [id, userId, accountId]
  );
  return r.rows[0]!;
}

export async function updateJobStatus(
  db: Db,
  id: string,
  status: InvestmentsUploadJobStatus,
  stageMessage: string
): Promise<void> {
  await db.query(
    `UPDATE investments_upload_jobs
     SET status = $2, stage_message = $3, updated_at = now()
     WHERE id = $1`,
    [id, status, stageMessage]
  );
}

export async function completeJob(
  db: Db,
  id: string,
  result: Record<string, unknown>
): Promise<void> {
  await db.query(
    `UPDATE investments_upload_jobs
     SET status = 'COMPLETED', result = $2, stage_message = 'Done', updated_at = now()
     WHERE id = $1`,
    [id, JSON.stringify(result)]
  );
}

export async function failJob(db: Db, id: string, errorMessage: string): Promise<void> {
  await db.query(
    `UPDATE investments_upload_jobs
     SET status = 'FAILED', error_message = $2, stage_message = 'Processing failed', updated_at = now()
     WHERE id = $1`,
    [id, errorMessage]
  );
}

export async function setAwaitingConfirmation(
  db: Db,
  id: string,
  payload: Record<string, unknown>
): Promise<void> {
  await db.query(
    `UPDATE investments_upload_jobs
     SET status = 'AWAITING_CONFIRMATION',
         result = $2,
         stage_message = 'Awaiting your confirmation',
         updated_at = now()
     WHERE id = $1`,
    [id, JSON.stringify(payload)]
  );
}

export async function rejectJob(db: Db, id: string): Promise<void> {
  await db.query(
    `UPDATE investments_upload_jobs
     SET status = 'REJECTED',
         result = NULL,
         stage_message = 'Import cancelled',
         updated_at = now()
     WHERE id = $1`,
    [id]
  );
}

export async function getJob(
  db: Db,
  id: string,
  userId: bigint
): Promise<InvestmentsUploadJobRow | null> {
  const r = await db.query<InvestmentsUploadJobRow>(
    `SELECT * FROM investments_upload_jobs WHERE id = $1 AND user_id = $2`,
    [id, userId]
  );
  return r.rows[0] ?? null;
}
