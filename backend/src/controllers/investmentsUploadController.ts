import type { Response } from "express";
import { randomUUID } from "crypto";
import { unlinkSync } from "fs";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import { pool } from "../db/pool.js";
import * as accountRepo from "../repositories/investmentsAccountRepository.js";
import * as jobRepo from "../repositories/investmentsUploadJobRepository.js";
import {
  processInvestmentsUpload,
  confirmInvestmentsUpload,
  rejectInvestmentsUpload,
} from "../services/investmentsUploadProcessingService.js";
import { HttpError } from "../utils/errors.js";

type MulterFiles = {
  holdings?: Express.Multer.File[];
  tradeBook?: Express.Multer.File[];
};

const uploadBodySchema = z.object({
  accountId: z.string().min(1),
});

export async function uploadFiles(
  req: AuthedRequest & { files?: MulterFiles },
  res: Response
): Promise<void> {
  const holdingsFile = req.files?.holdings?.[0];
  const tradeBookFile = req.files?.tradeBook?.[0];

  const cleanup = () => {
    for (const f of [holdingsFile, tradeBookFile]) {
      if (!f) continue;
      try {
        unlinkSync(f.path);
      } catch {
        /* non-fatal */
      }
    }
  };

  if (!holdingsFile || !tradeBookFile) {
    cleanup();
    throw new HttpError(400, "Both a Holdings file and a Trade Book file are required");
  }

  try {
    const body = uploadBodySchema.parse(req.body);
    const accountId = BigInt(body.accountId);

    const account = await accountRepo.getAccountForUser(pool, req.userId, accountId);
    if (!account) {
      throw new HttpError(404, "Investments account not found");
    }

    const jobId = randomUUID();
    await jobRepo.createJob(pool, jobId, req.userId, accountId);
    await jobRepo.updateJobStatus(pool, jobId, "PARSING", "Reading files...");

    // Hand off file ownership to the pipeline — its finally block cleans up.
    setImmediate(() => {
      void processInvestmentsUpload(jobId, req.userId, accountId, holdingsFile.path, tradeBookFile.path);
    });

    res.status(202).json({ jobId, status: "PARSING" });
  } catch (err) {
    cleanup();
    throw err;
  }
}

export async function getStatus(req: AuthedRequest, res: Response): Promise<void> {
  const jobId = z.string().min(1).parse(req.query.jobId);
  const job = await jobRepo.getJob(pool, jobId, req.userId);
  if (!job) throw new HttpError(404, "Job not found");

  if (job.status === "COMPLETED") {
    res.json({ status: "COMPLETED", result: job.result });
    return;
  }

  if (job.status === "FAILED") {
    res.json({ status: "FAILED", errorMessage: job.error_message ?? "Processing failed" });
    return;
  }

  if (job.status === "AWAITING_CONFIRMATION") {
    const r = job.result as Record<string, unknown>;
    res.json({
      status: "AWAITING_CONFIRMATION",
      confirmationData: {
        mismatches: r["mismatches"],
        totalExtracted: r["totalExtracted"] ?? r["total_extracted"],
        duplicatesSkipped: r["duplicatesSkipped"] ?? r["duplicates_skipped"],
        pendingCount: (r["pendingTransactions"] as unknown[] | undefined)?.length ?? 0,
      },
    });
    return;
  }

  if (job.status === "REJECTED") {
    res.json({ status: "REJECTED" });
    return;
  }

  res.json({ status: job.status, message: job.stage_message ?? job.status });
}

const mismatchResolutionSchema = z.object({
  accountAssetId: z.string().min(1),
  createDummy: z.boolean(),
});

const confirmBodySchema = z.object({
  jobId: z.string().min(1),
  mismatchResolutions: z.array(mismatchResolutionSchema).default([]),
});

export async function confirmUpload(req: AuthedRequest, res: Response): Promise<void> {
  const body = confirmBodySchema.parse(req.body);
  const summary = await confirmInvestmentsUpload(req.userId, body.jobId, body.mismatchResolutions);
  console.log(
    `[investments][job:${body.jobId}] ✅ Confirmed — inserted=${summary.totalInserted}, ` +
      `dummiesCreated=${summary.dummiesCreated}, skipped=${summary.duplicatesSkipped}`
  );
  res.json({ status: "COMPLETED", ...summary });
}

const rejectBodySchema = z.object({
  jobId: z.string().min(1),
});

export async function rejectUpload(req: AuthedRequest, res: Response): Promise<void> {
  const body = rejectBodySchema.parse(req.body);
  await rejectInvestmentsUpload(req.userId, body.jobId);
  console.log(`[investments][job:${body.jobId}] 🚫 Rejected — all pending trades discarded`);
  res.json({ status: "REJECTED" });
}
