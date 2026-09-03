-- =====================================================
-- Queue RPC mutators (0415)
-- =====================================================
-- 0310 only calls queue_read. The first coverage run showed queue_pop,
-- queue_archive and queue_delete (0170_queue.sql, the PostgREST /rpc surface
-- over pgmq) were never executed. This file pins their behaviour for an
-- administrator on a queue registered through the queues entity.
--
-- The queue is created through the entity as the owner (as 0310 does) and the
-- messages are sent with pgmq.send; the RPCs are then called as user3. The
-- second half pins the per-queue authorization added for release review S4:
-- queues.view_permission gates queue_read, queues.manage_permission gates the
-- three mutators, unregistered names are refused, and the read arguments are
-- clamped.
BEGIN;

SELECT plan(36);

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
-- admin and must name an existing permission.
SELECT is((SELECT view_permission FROM queues WHERE queue_name = 'raci_notify'), 'admin',
    'queues.view_permission: defaults to admin');
SELECT is((SELECT manage_permission FROM queues WHERE queue_name = 'raci_notify'), 'admin',
    'queues.manage_permission: defaults to admin');
SELECT throws_ok($$UPDATE queues SET view_permission = 'no:such' WHERE queue_name = 'rpc_q'$$,
    NULL, 'View permission "no:such" does not exist in permissions table',
    'queues.view_permission: an unknown permission name is rejected');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('rpcq:view',   'Read the rpc_q queue',    1),
    ('rpcq:manage', 'Consume the rpc_q queue', 1);
UPDATE queues SET view_permission = 'rpcq:view', manage_permission = 'rpcq:manage'
WHERE queue_name = 'rpc_q';
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
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
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
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
SELECT throws_ok($$SELECT public.queue_read('no_such_queue', 0, 1)$$, '42704', NULL,
    'queue_read: an admin is told the queue is not registered');

RESET ROLE;
DELETE FROM queues WHERE queue_name = 'rpc_q';

SELECT * FROM finish();
ROLLBACK;
