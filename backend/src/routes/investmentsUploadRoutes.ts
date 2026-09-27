import { Router } from "express";
import multer from "multer";
import { mkdirSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { randomUUID } from "crypto";
import { authMiddleware, type AuthedRequest } from "../middleware/authMiddleware.js";
import { asyncHandler } from "../utils/asyncHandler.js";
import { env } from "../config/env.js";
import * as investmentsUploadController from "../controllers/investmentsUploadController.js";

// ── Multer config (independent temp dir + limits from Banking's statement upload) ──

const uploadDir = join(tmpdir(), "finapp-investments-uploads");
mkdirSync(uploadDir, { recursive: true });

const storage = multer.diskStorage({
  destination: uploadDir,
  filename: (_req, file, cb) => {
    const ext = file.originalname.toLowerCase().endsWith(".csv") ? ".csv" : ".xlsx";
    cb(null, `${randomUUID()}${ext}`);
  },
});

const isSpreadsheet = (file: Express.Multer.File): boolean => {
  const name = file.originalname.toLowerCase();
  return (
    name.endsWith(".xlsx") ||
    name.endsWith(".xls") ||
    name.endsWith(".csv") ||
    file.mimetype === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ||
    file.mimetype === "application/vnd.ms-excel" ||
    file.mimetype === "text/csv" ||
    // Flutter Web often sends application/octet-stream regardless of type.
    file.mimetype === "application/octet-stream"
  );
};

const upload = multer({
  storage,
  limits: { fileSize: env.investmentsMaxUploadFileSizeKb * 1024 },
  fileFilter: (_req, file, cb) => {
    if (isSpreadsheet(file)) {
      cb(null, true);
    } else {
      cb(new Error("Only .xlsx, .xls, or .csv files are allowed"));
    }
  },
});

const twoFileUpload = upload.fields([
  { name: "holdings", maxCount: 1 },
  { name: "tradeBook", maxCount: 1 },
]);

// ── Router ────────────────────────────────────────────────────────────────────

export const investmentsUploadRouter = Router();

investmentsUploadRouter.use(authMiddleware);

investmentsUploadRouter.post(
  "/upload",
  twoFileUpload,
  asyncHandler((req, res) =>
    investmentsUploadController.uploadFiles(
      req as AuthedRequest & {
        files?: { holdings?: Express.Multer.File[]; tradeBook?: Express.Multer.File[] };
      },
      res
    )
  )
);

investmentsUploadRouter.get(
  "/status",
  asyncHandler((req, res) => investmentsUploadController.getStatus(req as AuthedRequest, res))
);

investmentsUploadRouter.post(
  "/confirm",
  asyncHandler((req, res) => investmentsUploadController.confirmUpload(req as AuthedRequest, res))
);

investmentsUploadRouter.post(
  "/reject",
  asyncHandler((req, res) => investmentsUploadController.rejectUpload(req as AuthedRequest, res))
);
