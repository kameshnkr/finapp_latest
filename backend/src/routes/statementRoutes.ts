import { Router } from "express";
import multer from "multer";
import { mkdirSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { randomUUID } from "crypto";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";
import * as statementController from "../controllers/statementController.js";

// ── Multer config ─────────────────────────────────────────────────────────────

const uploadDir = join(tmpdir(), "finapp-statements");
mkdirSync(uploadDir, { recursive: true });

const storage = multer.diskStorage({
  destination: uploadDir,
  filename: (_req, _file, cb) => {
    cb(null, `${randomUUID()}.pdf`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 20 * 1024 * 1024 }, // 20 MB
  fileFilter: (_req, file, cb) => {
    // Flutter Web sends application/octet-stream even for PDFs,
    // so fall back to checking the original filename extension.
    const isPdf =
      file.mimetype === "application/pdf" ||
      file.originalname.toLowerCase().endsWith(".pdf");
    if (isPdf) {
      cb(null, true);
    } else {
      cb(new Error("Only PDF files are allowed"));
    }
  },
});

// ── Router ────────────────────────────────────────────────────────────────────

export const statementRouter = Router();

statementRouter.use(authMiddleware);

statementRouter.post(
  "/upload",
  upload.single("file"),
  asyncHandler((req, res) =>
    statementController.uploadStatement(
      req as AuthedRequest & { file?: Express.Multer.File },
      res
    )
  )
);

statementRouter.get(
  "/status",
  asyncHandler((req, res) =>
    statementController.getStatus(req as AuthedRequest, res)
  )
);

statementRouter.post(
  "/confirm",
  asyncHandler((req, res) =>
    statementController.confirmStatement(req as AuthedRequest, res)
  )
);

statementRouter.post(
  "/reject",
  asyncHandler((req, res) =>
    statementController.rejectStatement(req as AuthedRequest, res)
  )
);
