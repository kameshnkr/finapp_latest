export type Direction = "credit" | "debit";

export type JobStatus =
  | "UPLOADING"
  | "PROCESSING"
  | "VALIDATING"
  | "SAVING"
  | "COMPLETED"
  | "FAILED"
  | "AWAITING_CONFIRMATION"
  | "REJECTED";
export type TxStatus = "draft" | "settled";
export type TxSource = "manual" | "gmail" | "statement";
export type TransactionType = "expense" | "expense_refund" | "transfer";

export type ResetType = "scheduled" | "manual";

export type ResetSchedule = {
  type: "every_month_on_date";
  /** Day of month (1–28). null when is_last_day_of_month is true. */
  date: number | null;
  /** When true, reset happens on the actual last day of each month (handles Feb, 30-day months, etc.). */
  is_last_day_of_month: boolean;
};
