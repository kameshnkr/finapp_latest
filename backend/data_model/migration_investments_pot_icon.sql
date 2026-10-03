-- Adds a user-selectable icon to investments_pots. Additive + backward
-- compatible: NOT NULL with a DEFAULT means every existing Pot (dev test
-- data AND live production Pots) is valid immediately with no backfill.
-- Keys are validated by a CHECK, mirroring every other enum-like column in
-- this schema (status, asset_class, etc.) — see
-- backend/src/constants/investmentsPotIcons.ts for the matching allow-list
-- that must be kept in sync with this constraint.

ALTER TABLE investments_pots
  ADD COLUMN icon_key text NOT NULL DEFAULT 'savings';

ALTER TABLE investments_pots
  ADD CONSTRAINT investments_pots_icon_key_check
  CHECK (icon_key = ANY (ARRAY[
    'savings', 'home', 'real_estate', 'car', 'travel', 'beach', 'school',
    'child_care', 'health', 'retirement', 'gold', 'currency', 'trending_up',
    'account_balance', 'wallet', 'shield', 'gift', 'celebration', 'pets',
    'business', 'laptop', 'phone', 'fitness', 'star', 'flag', 'charity'
  ]::text[]));
