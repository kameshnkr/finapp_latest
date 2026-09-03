-- Add category_type (fixed | variable) to every budget category.
-- Existing categories default to 'variable'.
ALTER TABLE budget_categories
  ADD COLUMN category_type TEXT NOT NULL DEFAULT 'variable'
  CHECK (category_type IN ('fixed', 'variable'));
