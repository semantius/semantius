-- =====================================================
-- Queue RPC mutators (0415)
-- =====================================================
-- 0310 only calls queue_read. The first coverage run showed queue_pop,
-- queue_archive and queue_delete (0170_queue.sql, the PostgREST /rpc surface
-- over pgmq) were never executed. This file pins their behaviour for an
-- administrator on a queue registered through the queues entity.
--
-- The queue is created through the entity as the owner (as 0310 does) and the
-- messages are sent with pgmq.send; the RPCs are then called as user3. Note
-- that the RPCs only require an authenticated caller today (see the release
-- review); this file deliberately pins the admin path only.
BEGIN;

SELECT plan(16);

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

DELETE FROM queues WHERE queue_name = 'rpc_q';

SELECT * FROM finish();
ROLLBACK;
