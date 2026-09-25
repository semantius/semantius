-- =====================================================
-- WEBHOOK RECEIVER - column constraints
-- =====================================================
-- Runs once. The entities are defined in 0380_webhook_receiver.jsonc.
-- webhook_receivers.table_name is a reference to entities, which the
-- dictionary creates as a nullable TEXT column. A receiver without a target
-- table means nothing, so the column is NOT NULL, defaulting to ''.
ALTER TABLE webhook_receivers ALTER COLUMN table_name SET DEFAULT '';
ALTER TABLE webhook_receivers ALTER COLUMN table_name SET NOT NULL;
