-- Test queue system: queues entity, queue_table_events, triggers, and RPC functions
BEGIN;

SELECT plan(40);

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

-- Use customers_test as target table (from seed data)
-- Test 20: Insert event handler for insert events
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'customer insert event', 'customers_test', 'insert'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_insert_on_customers_test'
    )),
    'Insert event handler should create trigger on customers_test'
);

-- Test 21: Changing table_name on event should raise error
SELECT throws_ok(
    $$UPDATE queue_table_events SET table_name = 'employees_test' WHERE table_name = 'customers_test'$$,
    'Cannot change table_name on a queue table event',
    'Changing table_name on event should raise error'
);

-- =====================================================
-- TEST: Event handlers queue records for insert
-- =====================================================

-- Test 22: Insert a record into customers_test and verify message is queued
INSERT INTO customers_test (customer_name) VALUES ('Queue Test Customer');

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10) WHERE message->>'op' = 'INSERT'),
    'Insert into customers_test should queue a message with op INSERT'
);

-- Test 23: Queued message should contain the record
SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->'record'->>'customer_name' = 'Queue Test Customer'),
    'Queued message should contain the inserted record data'
);

-- =====================================================
-- TEST: Event handlers for update events
-- =====================================================

-- Test 24: Create update event handler
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'employee update event', 'employees_test', 'update'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_update_on_employees_test'
    )),
    'Update event handler should create trigger on employees_test'
);

-- Test 25: Insert into employees_test should NOT trigger (update handler only)
-- First purge existing messages
SELECT pgmq.delete('test_q1', msg_id) FROM pgmq.read('test_q1', 0, 100);

INSERT INTO employees_test (full_name) VALUES ('Queue Test Employee');

SELECT is(
    (SELECT COUNT(*)::integer FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'employees_test' AND message->>'op' = 'INSERT'),
    0,
    'Insert into employees_test should NOT queue a message (update handler only)'
);

-- Test 26: Update employees_test SHOULD trigger
UPDATE employees_test SET full_name = 'Updated Employee' WHERE full_name = 'Queue Test Employee';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'employees_test' AND message->>'op' = 'UPDATE'),
    'Update of employees_test should queue a message with op UPDATE'
);

-- =====================================================
-- TEST: Event handlers for delete events
-- =====================================================

-- Test 27: Create delete event handler
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'product delete event', 'products_test', 'delete'
FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_delete_on_products_test'
    )),
    'Delete event handler should create trigger on products_test'
);

-- Purge messages
SELECT pgmq.delete('test_q1', msg_id) FROM pgmq.read('test_q1', 0, 100);

-- Test 28: Insert into products_test should NOT trigger (delete handler only)
INSERT INTO products_test (product_name, price) VALUES ('Queue Test Product', 9.99);

SELECT is(
    (SELECT COUNT(*)::integer FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'products_test' AND message->>'op' = 'INSERT'),
    0,
    'Insert into products_test should NOT queue a message (delete handler only)'
);

-- Test 29: Delete from products_test SHOULD trigger
DELETE FROM products_test WHERE product_name = 'Queue Test Product';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q1', 0, 10)
     WHERE message->>'table' = 'products_test' AND message->>'op' = 'DELETE'),
    'Delete from products_test should queue a message with op DELETE'
);

-- =====================================================
-- TEST: Event handler for change (insert + update + delete)
-- =====================================================

-- Create a second queue for change tests
INSERT INTO queues (queue_name) VALUES ('test_q2');

-- Test 30: Create change event handler using a different target table
-- Use departments table which has explicit seed IDs; fix sequence first
SELECT setval(pg_get_serial_sequence('departments', 'id'), (SELECT MAX(id) FROM departments));

INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'department change event', 'departments', 'change'
FROM queues WHERE queue_name = 'test_q2';

SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q2_change_on_departments'
    )),
    'Change event handler should create trigger on departments'
);

-- Test 31: Insert should trigger (change = insert + update + delete)
INSERT INTO departments (department_name) VALUES ('Queue Test Dept');

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'departments' AND message->>'op' = 'INSERT'),
    'Insert into departments should queue a message (change handler covers inserts)'
);

-- Test 32: Update should trigger
UPDATE departments SET department_name = 'Updated Dept' WHERE department_name = 'Queue Test Dept';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'departments' AND message->>'op' = 'UPDATE'),
    'Update departments should queue a message (change handler covers updates)'
);

-- Test 33: Delete should trigger
DELETE FROM departments WHERE department_name = 'Updated Dept';

SELECT ok(
    (SELECT COUNT(*) > 0 FROM pgmq.read('test_q2', 0, 10)
     WHERE message->>'table' = 'departments' AND message->>'op' = 'DELETE'),
    'Delete from departments should queue a message (change handler covers deletes)'
);

-- =====================================================
-- TEST: Remove event handler removes trigger
-- =====================================================

-- Test 34: Delete event handler should drop trigger
DELETE FROM queue_table_events WHERE table_name = 'customers_test';

SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'queue_test_q1_insert_on_customers_test'
    )),
    'Deleting event handler should remove trigger from customers_test'
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
