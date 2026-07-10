-- Add 'balance_adjustment' to the transaction_type CHECK constraint.
-- These transactions are created automatically when a user adjusts an account's
-- total balance via the balance-adjustment sheet.  They are inserted directly
-- as settled records and are never created through the normal draft → settle flow.

ALTER TABLE transactions
  DROP CONSTRAINT transactions_transaction_type_check,
  ADD CONSTRAINT transactions_transaction_type_check
    CHECK (transaction_type IN ('expense', 'expense_refund', 'transfer', 'balance_adjustment'));
