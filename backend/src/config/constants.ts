// Default user timezone. All period boundaries are computed in this timezone
// and stored as UTC in the database. Will become dynamic per-user in a future phase.
export const USER_TIMEZONE = "Asia/Kolkata";

// IST is UTC+5:30 with no DST – a fixed offset we can rely on for arithmetic.
export const USER_TIMEZONE_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;
