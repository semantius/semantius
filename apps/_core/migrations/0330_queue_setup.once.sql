-- =====================================================
-- QUEUE SYSTEM - column constraints
-- =====================================================
-- Runs once. The entities are defined in 0320_queue.jsonc. A queue without
-- its permissions is unusable, so both are required.

-- reference columns default to nullable in the DD model; both are mandatory
ALTER TABLE queues ALTER COLUMN view_permission SET NOT NULL;
ALTER TABLE queues ALTER COLUMN manage_permission SET NOT NULL;

-- queue_table_events.table_name is a reference to entities, which the
-- dictionary creates as a nullable TEXT column. A mapping without a table
-- means nothing, so the column is NOT NULL, defaulting to ''.
ALTER TABLE queue_table_events ALTER COLUMN table_name SET DEFAULT '';
ALTER TABLE queue_table_events ALTER COLUMN table_name SET NOT NULL;
