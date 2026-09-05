-- Test queue system: queues entity, queue_table_events, triggers, and RPC functions
--
-- Handler targets are nwind sample tables (apps/nwind): categories (insert),
-- shippers (update), suppliers (delete) and regions (change). All four have a
-- single required label column with defaults on everything else, so plain
-- label-only INSERTs work, and nwind resets every sequence after its data load.
-- `orders` already carries the persisted 'Order created' mapping
-- (queue_table_events.table_name is unique), so it is never mapped here.
BEGIN;

SELECT plan(42);

-- Authenticate as admin
SELECT authenticate_as('user3');

-- =====================================================
-- TEST: queues entity exists and has correct structure
-- =====================================================

-- Test 1: queues entity metadata exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'queues')),
    'queues entity metadata should exist'
);

-- Test 2: queues table exists in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'queues')),
    'queues table should exist in database'
);

-- Test 3: queues label_column is queue_name
SELECT is(
    (SELECT label_column FROM entities WHERE table_name = 'queues'),
    'queue_name',
    'queues label_column should be queue_name'
);

-- Test 4: queues has queue_name field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'queues' AND field_name = 'queue_name')),
    'queues should have queue_name field'
);

-- Test 5: queue_name field is unique
SELECT ok(
    (SELECT unique_value FROM fields WHERE table_name = 'queues' AND field_name = 'queue_name'),
    'queue_name field should be unique'
);

-- =====================================================
-- TEST: queue_table_events entity exists and has correct structure
-- =====================================================

-- Test 6: queue_table_events entity metadata exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'queue_table_events')),
    'queue_table_events entity metadata should exist'
);

-- Test 7: queue_table_events table exists in database
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'queue_table_events')),
    'queue_table_events table should exist in database'
);

-- Test 8: queue_table_events label_column is event_name
SELECT is(
    (SELECT label_column FROM entities WHERE table_name = 'queue_table_events'),
    'event_name',
    'queue_table_events label_column should be event_name'
);

-- Test 9: queue_table_events has queue_id field (parent)
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'queue_id')),
    'queue_table_events should have queue_id parent field'
);

-- Test 10: queue_table_events has table_name field (reference to entities)
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'table_name')),
    'queue_table_events should have table_name field'
);

-- Test 11: table_name field references entities
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'table_name'),
    'entities',
    'queue_table_events table_name should reference entities'
);

-- Test 12: table_name field is required
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'table_name'),
    'required',
    'queue_table_events table_name should be required'
);

-- Test 13: table_name field is unique
SELECT ok(
    (SELECT unique_value FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'table_name'),
    'queue_table_events table_name should be unique'
);

-- Test 14: queue_table_events has event_handler enum field
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'event_handler')),
    'queue_table_events should have event_handler field'
);

-- Test 15: event_handler has correct enum values
SELECT ok(
    (SELECT enum_values @> '["insert", "update", "upsert", "delete", "change"]'::jsonb
     FROM fields WHERE table_name = 'queue_table_events' AND field_name = 'event_handler'),
    'event_handler should have correct enum values'
);

-- =====================================================
-- TEST: Creating a queue creates pgmq queue
-- =====================================================

-- Switch to owner for queue operations (pgmq needs schema access)
RESET ROLE;

-- Test 16: Insert a queue and verify pgmq table exists
INSERT INTO queues (queue_name) VALUES ('test_q1');

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pgmq.meta WHERE queue_name = 'test_q1'
    )),
    'Creating a queue should register it in pgmq.meta'
);

-- Test 17: pgmq queue table exists in pgmq schema
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'pgmq' AND table_name = 'q_test_q1'
    )),
    'pgmq queue table q_test_q1 should exist in pgmq schema'
);

-- Test 18: pgmq archive table exists in pgmq schema
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'pgmq' AND table_name = 'a_test_q1'
    )),
    'pgmq archive table a_test_q1 should exist in pgmq schema'
);

-- =====================================================
-- TEST: Cannot change queue_name
-- =====================================================

-- Test 19: Changing queue_name should raise error
SELECT throws_ok(
    $$UPDATE queues SET queue_name = 'renamed_q' WHERE queue_name = 'test_q1'$$,
    'Cannot change queue_name after creation',
    'Changing queue_name should raise error'
);

-- =====================================================
-- TEST: Add event handler, verify trigger creation
-- =====================================================

-- Use nwind categories as the insert target
-- Test 20: Insert event handler for insert events
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'category insert event', 'categories', 'insert'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_insert_on_categories'
    )),
    'Insert event handler should create trigger on categories'
);

-- Test 21: Changing table_name on event should raise error
SELECT throws_ok(
    $$UPDATE queue_table_events SET table_name = 'shippers' WHERE table_name = 'categories'$$,
    'Cannot change table_name on a queue table event',
    'Changing table_name on event should raise error'
);

-- =====================================================
-- TEST: Event handlers queue records for insert
-- =====================================================

-- Test 22: Insert a record into categories and verify message is queued
INSERT INTO categories (category_name) VALUES ('Queue Test Category');

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10) WHERE message->>'op' = 'INSERT'),
    'Insert into categories should queue a message with op INSERT'
);

-- Test 23: Queued message should contain id_field and id_value matching the inserted record
SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'id_field' = 'id'
       AND (message->'id_value')::bigint = (SELECT MAX(id) FROM categories WHERE category_name = 'Queue Test Category')),
    'Queued message should contain id_field=id and id_value matching the inserted record id'
);

-- Test 24: Queued message should contain message_type = entity_event and event_type = insert
SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'message_type' = 'entity_event'
       AND message->>'event_type' = 'insert'),
    'Queued message should contain message_type=entity_event and event_type=insert'
);

-- =====================================================
-- TEST: Event handlers for update events
-- =====================================================

-- Test 24: Create update event handler
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'shipper update event', 'shippers', 'update'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_update_on_shippers'
    )),
    'Update event handler should create trigger on shippers'
);

-- Test 25: Insert into shippers should NOT trigger (update handler only)
-- First purge existing messages
SELECT pgmq.delete('test_q1', msg_id) FROM pgmq.read('test_q1', 0, 100);

INSERT INTO shippers (company_name) VALUES ('Queue Test Shipper');

SELECT is(
    (SELECT COUNT(*)::integer FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'shippers' AND message->>'op' = 'INSERT'),
    0,
    'Insert into shippers should NOT queue a message (update handler only)'
);

-- Test 26: Update shippers SHOULD trigger
UPDATE shippers SET company_name = 'Updated Shipper' WHERE company_name = 'Queue Test Shipper';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'shippers' AND message->>'op' = 'UPDATE'),
    'Update of shippers should queue a message with op UPDATE'
);

-- =====================================================
-- TEST: Event handlers for delete events
-- =====================================================

-- Test 27: Create delete event handler
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'supplier delete event', 'suppliers', 'delete'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_delete_on_suppliers'
    )),
    'Delete event handler should create trigger on suppliers'
);

-- Purge messages
SELECT pgmq.delete('test_q1', msg_id) FROM pgmq.read('test_q1', 0, 100);

-- Test 28: Insert into suppliers should NOT trigger (delete handler only)
INSERT INTO suppliers (company_name) VALUES ('Queue Test Supplier');

SELECT is(
    (SELECT COUNT(*)::integer FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'suppliers' AND message->>'op' = 'INSERT'),
    0,
    'Insert into suppliers should NOT queue a message (delete handler only)'
);

-- Test 29: Delete from suppliers SHOULD trigger
DELETE FROM suppliers WHERE company_name = 'Queue Test Supplier';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'suppliers' AND message->>'op' = 'DELETE'),
    'Delete from suppliers should queue a message with op DELETE'
);

-- =====================================================
-- TEST: Event handler for change (insert + update + delete)
-- =====================================================

-- Create a second queue for change tests
INSERT INTO queues (queue_name) VALUES ('test_q2');

-- Test 30: Create change event handler using a different target table (regions)
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'region change event', 'regions', 'change'
FROM queues WHERE queue_name = 'test_q2';

-- A multi-event handler installs one trigger per event, because a trigger that
-- carries a transition table may only be defined for a single event. The
-- handler name does not appear in any of them; the event does.
SELECT is(
    (SELECT array_agg(tgname::text ORDER BY tgname)
     FROM pg_trigger
     WHERE tgrelid = 'public.regions'::regclass
       AND starts_with(tgname::text, 'queue_test_q2_')),
    ARRAY['queue_test_q2_delete_on_regions',
          'queue_test_q2_insert_on_regions',
          'queue_test_q2_update_on_regions'],
    'Change event handler should create one trigger per event on regions'
);

SELECT ok(
    (SELECT bool_and((tgtype & 1) = 0)
     FROM pg_trigger
     WHERE tgrelid = 'public.regions'::regclass
       AND starts_with(tgname::text, 'queue_test_q2_')),
    'Queue triggers should be statement-level, not row-level'
);

-- Test 31: Insert should trigger (change = insert + update + delete)
INSERT INTO regions (region_description) VALUES ('Queue Test Region');

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'regions' AND message->>'op' = 'INSERT'),
    'Insert into regions should queue a message (change handler covers inserts)'
);

-- Test 32: Update should trigger
UPDATE regions SET region_description = 'Updated Region' WHERE region_description = 'Queue Test Region';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'regions' AND message->>'op' = 'UPDATE'),
    'Update regions should queue a message (change handler covers updates)'
);

-- Test 33: Delete should trigger
DELETE FROM regions WHERE region_description = 'Updated Region';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'regions' AND message->>'op' = 'DELETE'),
    'Delete from regions should queue a message (change handler covers deletes)'
);

-- =====================================================
-- TEST: Remove event handler removes trigger
-- =====================================================

-- Test 34: Delete event handler should drop trigger
DELETE FROM queue_table_events WHERE table_name = 'categories';

SELECT is(
    (SELECT count(*)
     FROM pg_trigger
     WHERE tgrelid = 'public.categories'::regclass
       AND starts_with(tgname::text, 'queue_')),
    0::bigint,
    'Deleting event handler should remove every queue trigger from categories'
);

-- =====================================================
-- TEST: Deleting queue deletes pgmq queue
-- =====================================================

-- Test 35: Delete queue should drop pgmq queue
DELETE FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM pgmq.meta WHERE queue_name = 'test_q1'
    )),
    'Deleting queue should remove it from pgmq.meta'
);

-- =====================================================
-- TEST: RPC functions exist
-- =====================================================

-- Test 36: queue_read function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_read' AND n.nspname = 'public'
    )),
    'queue_read function should exist in public schema'
);

-- Test 37: queue_pop function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_pop' AND n.nspname = 'public'
    )),
    'queue_pop function should exist in public schema'
);

-- Test 38: queue_archive function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_archive' AND n.nspname = 'public'
    )),
    'queue_archive function should exist in public schema'
);

-- Test 39: queue_delete function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_delete' AND n.nspname = 'public'
    )),
    'queue_delete function should exist in public schema'
);

-- =====================================================
-- TEST: RPC queue_read returns data
-- =====================================================

-- Authenticate as admin for RPC test
SELECT authenticate_as('user3');

-- Test 40: queue_read returns messages from test_q2
SELECT ok(
    (SELECT public.queue_read('test_q2', 1, 10) IS NOT NULL),
    'queue_read should return non-null result'
);

-- =====================================================
-- CLEANUP
-- =====================================================

RESET ROLE;
DELETE FROM queues WHERE queue_name = 'test_q2';

SELECT * FROM finish();
ROLLBACK;
