import type { Response } from "express";
import { randomUUID } from "crypto";
import { unlinkSync } from "fs";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import { pool } from "../db/pool.js";
import * as jobRepo from "../repositories/statementJobRepository.js";
import * as txRepo from "../repositories/transactionRepository.js";
import type { StatementDraftItem } from "../repositories/transactionRepository.js";
import { computeFingerprint, processStatement } from "../services/statementProcessingService.js";
import { HttpError } from "../utils/errors.js";

const uploadBodySchema = z.object({
  accountId: z.string().min(1),
  // Multipart fields are always strings; accept 'true'/'false', default to null (auto-detect)
  isLatestStatement: z.enum(["true", "false"]).optional(),
});

export async function uploadStatement(
  req: AuthedRequest & { file?: Express.Multer.File },
  res: Response
): Promise<void> {
  if (!req.file) {
    throw new HttpError(400, "PDF file is required");
  }

  // Capture file path immediately — must be cleaned up in ALL error paths
  // before processStatement takes ownership of it.
  const filePath = req.file.path;

  try {
    const body = uploadBodySchema.parse(req.body);
    const accountId = BigInt(body.accountId);

    // Verify the account belongs to the user
    const accCheck = await pool.query(
      `SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2`,
      [accountId, req.userId]
    );
    if ((accCheck.rowCount ?? 0) === 0) {
      throw new HttpError(404, "Account not found");
    }

    const isLatestStatement =
      body.isLatestStatement === "true" ? true :
      body.isLatestStatement === "false" ? false :
      null;

    const jobId = randomUUID();
    await jobRepo.createJob(pool, jobId, req.userId, accountId);

    // Immediately move job to PROCESSING before kicking off async work
    await jobRepo.updateJobStatus(pool, jobId, "PROCESSING", "Extracting transactions...");

    // Hand off file ownership to processStatement — its finally block handles cleanup
    setImmediate(() => {
      void processStatement(jobId, req.userId, accountId, filePath, isLatestStatement);
    });

    res.status(202).json({ job_id: jobId, status: "PROCESSING" });
  } catch (err) {
    // processStatement never started — delete the multer file ourselves
    try { unlinkSync(filePath); } catch { /* non-fatal */ }
    throw err;
  }
}

export async function getStatus(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const jobId = z.string().min(1).parse(req.query.job_id);
  const job = await jobRepo.getJob(pool, jobId, req.userId);
  if (!job) throw new HttpError(404, "Job not found");

  if (job.status === "COMPLETED") {
    res.json({ status: "COMPLETED", result: job.result });
    return;
  }

  if (job.status === "FAILED") {
    res.json({
      status: "FAILED",
      error_message: job.error_message ?? "Processing failed",
    });
    return;
  }

  if (job.status === "AWAITING_CONFIRMATION") {
    const r = job.result as Record<string, unknown>;
    res.json({
      status: "AWAITING_CONFIRMATION",
      confirmation_data: {
        delta: r["delta"],
        allowed_delta: r["allowed_delta"],
        delta_status: r["delta_status"],
        dummy_type: r["dummy_type"],
        latest_date: r["latest_date"],
        total_extracted: r["total_extracted"],
        duplicates_skipped: r["duplicates_skipped"],
        pending_count: (r["pending_transactions"] as unknown[])?.length ?? 0,
        acct_delta: r["acct_delta"] ?? null,
        acct_dummy_type: r["acct_dummy_type"] ?? null,
        acct_db_balance: r["acct_db_balance"] ?? null,
        acct_projected_balance: r["acct_projected_balance"] ?? null,
        acct_closing_balance: r["acct_closing_balance"] ?? null,
      },
    });
    return;
  }

  if (job.status === "REJECTED") {
    res.json({ status: "REJECTED" });
    return;
  }

  res.json({
    status: job.status,
    message: job.stage_message ?? job.status,
  });
}

const confirmBodySchema = z.object({
  job_id: z.string().min(1),
  create_dummy: z.boolean(),
  create_account_balance_dummy: z.boolean().optional().default(false),
});

export async function confirmStatement(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const body = confirmBodySchema.parse(req.body);
  const job = await jobRepo.getJob(pool, body.job_id, req.userId);
  if (!job) throw new HttpError(404, "Job not found");
  if (job.status !== "AWAITING_CONFIRMATION") {
    throw new HttpError(409, `Job is not awaiting confirmation (status: ${job.status})`);
  }

  const r = job.result as Record<string, unknown>;
  const pendingTransactions = r["pending_transactions"] as StatementDraftItem[];
  const totalExtracted      = r["total_extracted"] as number;
  const duplicatesSkipped   = r["duplicates_skipped"] as number;
  const delta               = r["delta"] as number;
  const dummyType           = r["dummy_type"] as "CREDIT" | "DEBIT";
  const latestDate          = r["latest_date"] as string;
  const acctDelta           = r["acct_delta"] as number | null;
  const acctDummyType       = r["acct_dummy_type"] as "CREDIT" | "DEBIT" | null;

  await jobRepo.updateJobStatus(pool, body.job_id, "SAVING", "Saving drafts...");

  // Re-check fingerprints in case a concurrent upload already inserted some
  const allFingerprints = pendingTransactions.map((i) => i.fingerprint);
  const existing = await txRepo.findExistingFingerprints(pool, allFingerprints, req.userId);
  const toInsert = pendingTransactions.filter((i) => !existing.has(i.fingerprint));
  const extraSkipped = pendingTransactions.length - toInsert.length;

  const totalInserted = await txRepo.insertStatementDrafts(pool, req.userId, job.account_id, toInsert);

  // ── Internal balance dummy ────────────────────────────────────────────────
  let dummyInserted = 0;
  if (body.create_dummy && delta > 0 && latestDate) {
    const dummyDesc = "Balance adjustment";
    const dummyFp = computeFingerprint(
      job.account_id,
      latestDate,
      delta.toFixed(2),
      dummyDesc,
      dummyType
    );
    const dummyItem: StatementDraftItem = {
      direction: dummyType === "CREDIT" ? "credit" : "debit",
      amount: delta.toFixed(2),
      description: dummyDesc,
      descriptionReadable: "Balance adjustment",
      transactionDate: latestDate,
      // Use the highest seq among all pending transactions so this dummy sorts last
      statementSeq: pendingTransactions.reduce((max, t) => Math.max(max, t.statementSeq), totalExtracted - 1) + 1,
      fingerprint: dummyFp,
    };
    const existingDummy = await txRepo.findExistingFingerprints(pool, [dummyFp], req.userId);
    if (!existingDummy.has(dummyFp)) {
      await txRepo.insertStatementDrafts(pool, req.userId, job.account_id, [dummyItem]);
      dummyInserted = 1;
    }
  }

  // ── Account balance reconciliation dummy ──────────────────────────────────
  let acctDummyInserted = 0;
  if (body.create_account_balance_dummy && acctDelta && acctDelta > 0 && acctDummyType && latestDate) {
    const dummyDesc = "Account balance reconciliation";
    const dummyFp = computeFingerprint(
      job.account_id,
      latestDate,
      acctDelta.toFixed(2),
      dummyDesc,
      acctDummyType
    );
    const dummyItem: StatementDraftItem = {
      direction: acctDummyType === "CREDIT" ? "credit" : "debit",
      amount: acctDelta.toFixed(2),
      description: dummyDesc,
      descriptionReadable: "Account balance reconciliation",
      transactionDate: latestDate,
      statementSeq: pendingTransactions.reduce((max, t) => Math.max(max, t.statementSeq), totalExtracted - 1) + 2,
      fingerprint: dummyFp,
    };
    const existingDummy = await txRepo.findExistingFingerprints(pool, [dummyFp], req.userId);
    if (!existingDummy.has(dummyFp)) {
      await txRepo.insertStatementDrafts(pool, req.userId, job.account_id, [dummyItem]);
      acctDummyInserted = 1;
    }
  }

  const anyDummyInserted = dummyInserted > 0 || acctDummyInserted > 0;

  await jobRepo.completeJob(pool, body.job_id, {
    total_extracted: totalExtracted,
    total_inserted: totalInserted + dummyInserted + acctDummyInserted,
    duplicates_skipped: duplicatesSkipped + extraSkipped,
    validation_status: anyDummyInserted ? "SUCCESS" : "REVIEW_REQUIRED",
    dummy_inserted: dummyInserted > 0,
    acct_dummy_inserted: acctDummyInserted > 0,
  });

  console.log(
    `[statement][job:${body.job_id}] ✅ Confirmed — inserted=${totalInserted}, ` +
      `dummyInserted=${dummyInserted}, acctDummyInserted=${acctDummyInserted}, extraSkipped=${extraSkipped}`
  );

  res.json({ status: "COMPLETED" });
}

const rejectBodySchema = z.object({
  job_id: z.string().min(1),
});

export async function rejectStatement(
  req: AuthedRequest,
  res: Response
): Promise<void> {
  const body = rejectBodySchema.parse(req.body);
  const job = await jobRepo.getJob(pool, body.job_id, req.userId);
  if (!job) throw new HttpError(404, "Job not found");
  if (job.status !== "AWAITING_CONFIRMATION") {
    throw new HttpError(409, `Job is not awaiting confirmation (status: ${job.status})`);
  }

  await jobRepo.rejectJob(pool, body.job_id);
  console.log(`[statement][job:${body.job_id}] 🚫 Rejected — all pending transactions discarded`);
  res.json({ status: "REJECTED" });
}
