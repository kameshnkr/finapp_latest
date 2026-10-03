/**
 * Fixed allow-list of Pot icon keys.
 *
 * The backend only ever stores and validates these string keys — it never
 * interprets or renders an icon. The actual Material icon each key maps to
 * lives solely in the Flutter app
 * (frontend_flutter/lib/ui/investments/pot_icons.dart). Keep both lists in
 * sync (same keys, same order for readability) whenever the pool changes.
 */
export const VALID_POT_ICON_KEYS = [
  "savings",
  "home",
  "real_estate",
  "car",
  "travel",
  "beach",
  "school",
  "child_care",
  "health",
  "retirement",
  "gold",
  "currency",
  "trending_up",
  "account_balance",
  "wallet",
  "shield",
  "gift",
  "celebration",
  "pets",
  "business",
  "laptop",
  "phone",
  "fitness",
  "star",
  "flag",
  "charity",
] as const;

export type PotIconKey = (typeof VALID_POT_ICON_KEYS)[number];

export const DEFAULT_POT_ICON_KEY: PotIconKey = "savings";

const VALID_SET = new Set<string>(VALID_POT_ICON_KEYS);

export function isValidPotIconKey(value: string): value is PotIconKey {
  return VALID_SET.has(value);
}
