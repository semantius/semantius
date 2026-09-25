-- The queue system: the queues entity, table events, triggers and the
-- queue RPCs.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. Queue system
--   2. Queue RPC mutators
BEGIN;

SELECT plan(80);

-- =====================================================
-- PART 1: Queue system
-- =====================================================
-- Test queue system: queues entity, queue_table_events, triggers, and RPC functions
--
-- Handler targets are nwind sample tables (apps/nwind): categories (insert),
-- shippers (update), suppliers (delete) and regions (change). All four have a
-- single required label column with defaults on everything else, so plain
-- label-only INSERTs work, and nwind resets every sequence after its data load.
-- `orders` already carries the persisted 'Order created' mapping
-- (queue_table_events.table_name is unique), so it is never mapped here.

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

-- test_q1 still holds the shippers (update) and suppliers (delete) mappings;
-- only the categories one was deleted above. Asserting that here is what stops
-- the trigger check below from passing on an empty set.

-- Test 35: the queue still has live mappings with triggers installed
SELECT ok(
    (SELECT count(*) FROM pg_trigger
      WHERE tgrelid IN ('public.shippers'::regclass, 'public.suppliers'::regclass)
        AND starts_with(tgname::text, 'queue_')) > 0,
    'setup: shippers and suppliers still carry queue triggers from test_q1'
);

-- Test 36: Delete queue should drop pgmq queue
DELETE FROM queues WHERE queue_name = 'test_q1';

SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM pgmq.meta WHERE queue_name = 'test_q1'
    )),
    'Deleting queue should remove it from pgmq.meta'
);

-- Test 37: the mappings go with the queue, and their triggers with them.
-- queue_before_delete deletes the mappings while the queues row still exists:
-- queue_event_after_delete builds the trigger names from the queue name, and an
-- ON DELETE CASCADE would take that name away before it could run.
SELECT is(
    (SELECT count(*) FROM pg_trigger
      WHERE tgrelid IN ('public.shippers'::regclass, 'public.suppliers'::regclass)
        AND starts_with(tgname::text, 'queue_')),
    0::bigint,
    'Deleting a queue drops the triggers of the mappings it still held'
);

-- =====================================================
-- TEST: RPC functions exist
-- =====================================================

-- Test 38: queue_read function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_read' AND n.nspname = 'public'
    )),
    'queue_read function should exist in public schema'
);

-- Test 39: queue_pop function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_pop' AND n.nspname = 'public'
    )),
    'queue_pop function should exist in public schema'
);

-- Test 40: queue_archive function exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proname = 'queue_archive' AND n.nspname = 'public'
    )),
    'queue_archive function should exist in public schema'
);

-- Test 41: queue_delete function exists
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

-- Test 42: queue_read returns messages from test_q2
SELECT ok(
    (SELECT public.queue_read('test_q2', 1, 10) IS NOT NULL),
    'queue_read should return non-null result'
);

-- =====================================================
-- CLEANUP
-- =====================================================

RESET ROLE;
DELETE FROM queues WHERE queue_name = 'test_q2';

-- =====================================================
-- PART 2: Queue RPC mutators
-- =====================================================
-- Part 1 only calls queue_read. The first coverage run showed queue_pop,
-- queue_archive and queue_delete (0340_queue.sql, the PostgREST /rpc surface
-- over pgmq) were never executed. This part pins their behavior for an
-- administrator on a queue registered through the queues entity.
--
-- The queue is created through the entity as the owner (as part 1 does) and the
-- messages are sent with pgmq.send; the RPCs are then called as user3. The
-- second half pins the per-queue authorization added for release review S4:
-- queues.view_permission gates queue_read, queues.manage_permission gates the
-- three mutators, unregistered names are refused, and the read arguments are
-- clamped.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

INSERT INTO queues (queue_name) VALUES ('rpc_q');
SELECT pgmq.send('rpc_q', '{"n":1}');
SELECT pgmq.send('rpc_q', '{"n":2}');
SELECT pgmq.send('rpc_q', '{"n":3}');

SELECT authenticate_as('user3');

-- queue_read leaves the messages in place (vt 0 keeps them visible)
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 3,
    'queue_read: returns every visible message');
SELECT is(public.queue_read('rpc_q', 0, 1)->0->'message'->>'n', '1',
    'queue_read: oldest message first');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 3,
    'queue_read: reading does not consume messages');

-- queue_pop consumes exactly one
SELECT is(public.queue_pop('rpc_q')->0->'message'->>'n', '1',
    'queue_pop: returns the oldest visible message');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 2,
    'queue_pop: the popped message is gone');

-- queue_archive moves one message to the archive
SELECT ok(public.queue_archive('rpc_q', (public.queue_read('rpc_q', 0, 1)->0->>'msg_id')::bigint),
    'queue_archive: returns true for an existing message');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 1,
    'queue_archive: the archived message left the queue');
SELECT ok(NOT public.queue_archive('rpc_q', 999999),
    'queue_archive: returns false for an unknown message id');

-- queue_delete removes one message permanently
SELECT ok(public.queue_delete('rpc_q', (public.queue_read('rpc_q', 0, 1)->0->>'msg_id')::bigint),
    'queue_delete: returns true for an existing message');
SELECT is(public.queue_read('rpc_q', 0, 10), '[]'::jsonb,
    'queue_read: an empty queue yields an empty JSON array');
SELECT is(public.queue_pop('rpc_q'), '[]'::jsonb,
    'queue_pop: an empty queue yields an empty JSON array');
SELECT ok(NOT public.queue_delete('rpc_q', 999999),
    'queue_delete: returns false for an unknown message id');

SELECT throws_ok($$SELECT public.queue_read('no_such_queue', 0, 1)$$, NULL, NULL,
    'queue_read: an unknown queue raises');
SELECT throws_ok($$SELECT public.queue_pop('no_such_queue')$$, NULL, NULL,
    'queue_pop: an unknown queue raises');

-- The archive table holds the archived payload (owner view, no RLS on pgmq)
RESET ROLE;
SELECT is((SELECT count(*)::int FROM pgmq.a_rpc_q), 1,
    'queue_archive: the message is in the archive table');
SELECT is((SELECT message->>'n' FROM pgmq.a_rpc_q), '2',
    'queue_archive: the archived payload is intact');

-- =====================================================
-- Per-queue authorization (release review S4)
-- =====================================================
-- Still the owner here (RESET ROLE above). Both permission fields default to
-- admin and are foreign keys to permissions(permission_name).
SELECT is((SELECT view_permission FROM queues WHERE queue_name = 'raci_notify'), 'admin',
    'queues.view_permission: defaults to admin');
SELECT is((SELECT manage_permission FROM queues WHERE queue_name = 'raci_notify'), 'admin',
    'queues.manage_permission: defaults to admin');
SELECT throws_ok($$UPDATE queues SET view_permission = 'no:such' WHERE queue_name = 'rpc_q'$$,
    '23503', NULL,
    'queues.view_permission: an unknown permission name is rejected by the foreign key');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('rpcq:view',   'Read the rpc_q queue',    1),
    ('rpcq:manage', 'Consume the rpc_q queue', 1);
UPDATE queues SET view_permission = 'rpcq:view', manage_permission = 'rpcq:manage'
WHERE queue_name = 'rpc_q';
INSERT INTO role_permissions (role_id, permission_name)
SELECT r.id, p.permission_name FROM roles r, permissions p
WHERE r.slug = 'northwind_sales' AND p.permission_name = 'rpcq:view';
SELECT pgmq.send('rpc_q', '{"n":4}');
SELECT pgmq.send('rpc_q', '{"n":5}');

-- user1 (User role) holds neither permission
SELECT authenticate_as('user1');
SELECT throws_ok($$SELECT public.queue_read('rpc_q', 0, 1)$$, '42501', NULL,
    'queue_read: denied without the view permission');
SELECT throws_ok($$SELECT public.queue_pop('rpc_q')$$, '42501', NULL,
    'queue_pop: denied without the manage permission');
SELECT throws_ok($$SELECT public.queue_archive('rpc_q', 1)$$, '42501', NULL,
    'queue_archive: denied without the manage permission');
SELECT throws_ok($$SELECT public.queue_delete('rpc_q', 1)$$, '42501', NULL,
    'queue_delete: denied without the manage permission');
SELECT throws_ok($$SELECT public.queue_read('no_such_queue', 0, 1)$$, '42501', NULL,
    'queue_read: an unregistered queue looks like a denied one to non-admins');
SELECT throws_ok($$SELECT public.queue_read('raci_notify', 0, 1)$$, '42501', NULL,
    'queue_read: a queue with default permissions is admin only');

-- user2 (Northwind Sales) holds rpcq:view only
SELECT authenticate_as('user2');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 2,
    'queue_read: allowed with the view permission');
SELECT throws_ok($$SELECT public.queue_pop('rpc_q')$$, '42501', NULL,
    'queue_pop: the view permission does not allow consuming');
SELECT throws_ok($$SELECT public.queue_archive('rpc_q', 1)$$, '42501', NULL,
    'queue_archive: the view permission does not allow consuming');
SELECT throws_ok($$SELECT public.queue_delete('rpc_q', 1)$$, '42501', NULL,
    'queue_delete: the view permission does not allow consuming');

-- grant rpcq:manage to the same role; authenticate_as clears the cache
RESET ROLE;
INSERT INTO role_permissions (role_id, permission_name)
SELECT r.id, p.permission_name FROM roles r, permissions p
WHERE r.slug = 'northwind_sales' AND p.permission_name = 'rpcq:manage';
SELECT authenticate_as('user2');
SELECT is(public.queue_pop('rpc_q')->0->'message'->>'n', '4',
    'queue_pop: allowed with the manage permission');
SELECT ok(public.queue_delete('rpc_q', (public.queue_read('rpc_q', 0, 1)->0->>'msg_id')::bigint),
    'queue_delete: allowed with the manage permission');

-- clamps (user3, admin): the queue is empty again
RESET ROLE;
SELECT pgmq.send('rpc_q', '{"n":6}');
SELECT pgmq.send('rpc_q', '{"n":7}');
SELECT authenticate_as('user3');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 0)), 1,
    'queue_read: a quantity below 1 is clamped to 1');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', -5, 10)), 2,
    'queue_read: a negative visibility timeout is clamped to 0');
SELECT ok((public.queue_read('rpc_q', 99999, 1)->0->>'vt')::timestamptz <= clock_timestamp() + interval '3601 seconds',
    'queue_read: the visibility timeout is clamped to one hour');
SELECT is(jsonb_array_length(public.queue_read('rpc_q', 0, 10)), 1,
    'queue_read: the clamped read still leased exactly one message');
SELECT throws_ok($$SELECT public.queue_read('no_such_queue', 0, 1)$$, '90504', NULL,
    'queue_read: an admin is told the queue is not registered');

RESET ROLE;
DELETE FROM queues WHERE queue_name = 'rpc_q';

SELECT * FROM finish();
ROLLBACK;
