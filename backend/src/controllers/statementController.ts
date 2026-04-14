import type { Response } from "express";
import { randomUUID } from "crypto";
import { unlinkSync } from "fs";
import { z } from "zod";
import type { AuthedRequest } from "../middleware/authMiddleware.js";
import { pool } from "../db/pool.js";
import * as jobRepo from "../repositories/statementJobRepository.js";
import { processStatement } from "../services/statementProcessingService.js";
import { HttpError } from "../utils/errors.js";

const uploadBodySchema = z.object({
  accountId: z.string().min(1),
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

    const jobId = randomUUID();
    await jobRepo.createJob(pool, jobId, req.userId, accountId);

    // Immediately move job to PROCESSING before kicking off async work
    await jobRepo.updateJobStatus(pool, jobId, "PROCESSING", "Extracting transactions...");

    // Hand off file ownership to processStatement — its finally block handles cleanup
    setImmediate(() => {
      void processStatement(jobId, req.userId, accountId, filePath);
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
    res.json({
      status: "COMPLETED",
      result: job.result,
    });
    return;
  }

  if (job.status === "FAILED") {
    res.json({
      status: "FAILED",
      error_message: job.error_message ?? "Processing failed",
    });
    return;
  }

  res.json({
    status: job.status,
    message: job.stage_message ?? job.status,
  });
}
