-- Reconciliation (db.reconcile): when a firing alert was first seen missing from
-- Alertmanager's active alerts. NULL while Alertmanager still has it.
ALTER TABLE alerts ADD COLUMN missing_since timestamptz;
