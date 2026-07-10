-- Migration: extend statement_jobs.status check constraint
-- Adds AWAITING_CONFIRMATION and REJECTED to the allowed status values.

ALTER TABLE statement_jobs
  DROP CONSTRAINT statement_jobs_status_check;

ALTER TABLE statement_jobs
  ADD CONSTRAINT statement_jobs_status_check
    CHECK (status IN (
      'UPLOADING',
      'PROCESSING',
      'VALIDATING',
      'SAVING',
      'COMPLETED',
      'FAILED',
      'AWAITING_CONFIRMATION',
      'REJECTED'
    ));
