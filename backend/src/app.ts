import express from "express";
import cors from "cors";
import type { CorsOptions } from "cors";
import { env } from "./config/env.js";
import { errorHandler } from "./middleware/errorHandler.js";
import { authRouter } from "./routes/authRoutes.js";
import { accountRouter } from "./routes/accountRoutes.js";
import { budgetRouter } from "./routes/budgetRoutes.js";
import { transactionRouter } from "./routes/transactionRoutes.js";
import { statementRouter } from "./routes/statementRoutes.js";

function buildCorsOptions(): CorsOptions {
  const common: CorsOptions = {
    credentials: false,
    allowedHeaders: ["Content-Type", "Authorization"],
    methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS", "HEAD"],
  };

  if (env.corsOrigin === "*") {
    return { ...common, origin: true };
  }
  const list = env.corsOrigin.split(",").map((s) => s.trim()).filter(Boolean);
  if (list.length > 1) {
    return { ...common, origin: list };
  }
  return { ...common, origin: list[0] ?? true };
}

export function createApp() {
  const app = express();

  app.use(cors(buildCorsOptions()));
  app.use(express.json({ limit: "1mb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  app.use("/api/auth", authRouter);
  app.use("/api/accounts", accountRouter);
  app.use("/api/budgets", budgetRouter);
  app.use("/api/transactions", transactionRouter);
  app.use("/api/statements", statementRouter);

  app.use(errorHandler);
  return app;
}
