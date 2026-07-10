-- =====================================================
-- Migration: Remove derived fields from budgets table
--
-- estimated  → computed at read time as SUM(budget_categories.estimated)
-- funds_available → computed at read time as SUM(account_budget_allocations.amount)
--
-- spent is retained as a stored aggregate (updated on category spend changes).
-- =====================================================

BEGIN;

ALTER TABLE budgets DROP COLUMN estimated;
ALTER TABLE budgets DROP COLUMN funds_available;

COMMIT;
