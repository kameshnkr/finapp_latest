// Investments-specific domain types. Kept fully separate from types/domain.ts
// (Banking) — no shared enums, intentionally, since the domains diverge.

export type InvestmentsAssetClass = "MUTUAL_FUND" | "STOCK" | "ETF" | "OTHER";

export type InvestmentsEntityStatus = "ACTIVE" | "ARCHIVED";

export type InvestmentsTransactionType = "BUY" | "SELL";

export type InvestmentsTransactionSource = "STATEMENT" | "MANUAL";

export type InvestmentsAllocationStatus = "UNALLOCATED" | "ALLOCATED";

export type InvestmentsAllocationMethod = "PERCENTAGE";

export type InvestmentsUploadJobStatus =
  | "UPLOADING"
  | "PARSING"
  | "VALIDATING"
  | "RECONCILING"
  | "AWAITING_CONFIRMATION"
  | "SAVING"
  | "COMPLETED"
  | "FAILED"
  | "REJECTED";
