-- =====================================================
-- pgmq operations (0306)
-- =====================================================
-- 0305 only smoke-tests pgmq.create/send/read. The first coverage run
-- (docs/pg_semantius-test-coverage.md) showed 65 of the 75 vendored pgmq
-- functions never execute, although every database role can call them. This
-- file exercises the message lifecycle (send_batch, read_with_poll, set_vt,
-- pop, archive, delete, purge_queue, metrics, list_queues, drop_queue), topic
-- routing (validate_routing_key, validate_topic_pattern, bind_topic,
-- test_routing, send_topic, list_topic_bindings, unbind_topic) and the
-- insert-notify throttle (enable/update/disable_notify_insert,
-- list_notify_insert_throttles).
--
-- Runs as the owner like 0305: the pgmq schema is not a PostgREST surface
-- and its tables carry no RLS. Queues live in the pgmq schema only (not in
-- the queues entity), so nothing else reacts to them. Everything rolls back.
BEGIN;

SELECT plan(50);

SELECT pgmq.create('ops_q');

-- =====================================================
-- GROUP 1: send_batch / read / metrics / list_queues
-- =====================================================
SELECT is((SELECT count(*)::int FROM pgmq.send_batch('ops_q', ARRAY['{"n":1}', '{"n":2}', '{"n":3}']::jsonb[])),
    3, 'send_batch: returns one message id per message');
SELECT is((SELECT count(*)::int FROM pgmq.send_batch('ops_q', ARRAY['{"n":4}']::jsonb[], ARRAY['{"h":"x"}']::jsonb[])),
    1, 'send_batch: the headers overload accepts one headers object per message');
SELECT is((SELECT headers->>'h' FROM pgmq.read('ops_q', 0, 10) WHERE message->>'n' = '4'),
    'x', 'send_batch: headers are stored with the message');
SELECT is((SELECT queue_length FROM pgmq.metrics('ops_q')), 4::bigint,
    'metrics: queue_length counts the queued messages');
SELECT ok((SELECT total_messages FROM pgmq.metrics('ops_q')) >= 4,
    'metrics: total_messages counts everything ever sent');
SELECT ok(EXISTS (SELECT 1 FROM pgmq.metrics_all() WHERE queue_name = 'ops_q'),
    'metrics_all: includes the queue');
SELECT ok(EXISTS (SELECT 1 FROM pgmq.list_queues() WHERE queue_name = 'ops_q' AND NOT is_partitioned AND NOT is_unlogged),
    'list_queues: lists the queue with its partitioned/unlogged flags');
SELECT is((SELECT count(*)::int FROM pgmq.read_with_poll('ops_q', 0, 2, 1, 50)),
    2, 'read_with_poll: returns up to qty visible messages without waiting');

-- =====================================================
-- GROUP 2: set_vt / pop / archive / delete / purge
-- =====================================================
SELECT is((SELECT count(*)::int FROM pgmq.set_vt('ops_q', (SELECT min(msg_id) FROM pgmq.q_ops_q), 3600)),
    1, 'set_vt: returns the updated message record');
SELECT ok((SELECT vt > clock_timestamp() + interval '59 minutes' FROM pgmq.q_ops_q WHERE msg_id = (SELECT min(msg_id) FROM pgmq.q_ops_q)),
    'set_vt: the visibility timeout moved forward');
SELECT is((SELECT count(*)::int FROM pgmq.read('ops_q', 0, 10)),
    3, 'read: a message hidden by set_vt is skipped');

SELECT is((SELECT message->>'n' FROM pgmq.pop('ops_q')), '2',
    'pop: returns the oldest visible message');
SELECT is((SELECT count(*)::int FROM pgmq.q_ops_q), 3,
    'pop: the popped message is removed from the queue');
SELECT is((SELECT count(*)::int FROM pgmq.pop('ops_q', 2)), 2,
    'pop: the qty argument pops several messages at once');
SELECT is((SELECT count(*)::int FROM pgmq.q_ops_q), 1,
    'pop: only the hidden message is left');

SELECT is((SELECT count(*)::int FROM pgmq.send_batch('ops_q', ARRAY['{"n":5}', '{"n":6}']::jsonb[])),
    2, 'fixture: two more messages');
SELECT is((SELECT count(*)::int FROM pgmq.archive('ops_q', (SELECT array_agg(msg_id) FROM pgmq.q_ops_q WHERE message->>'n' IN ('5', '6')))),
    2, 'archive(array): archives every listed message and returns their ids');
SELECT is((SELECT count(*)::int FROM pgmq.a_ops_q), 2,
    'archive: the messages moved to the archive table');
SELECT is((SELECT count(*)::int FROM pgmq.q_ops_q), 1,
    'archive: the messages left the queue table');
SELECT is((SELECT count(*)::int FROM pgmq.delete('ops_q', ARRAY[999999]::bigint[])),
    0, 'delete(array): unknown ids are ignored');
SELECT is((SELECT count(*)::int FROM pgmq.send_batch('ops_q', ARRAY['{"n":7}']::jsonb[])),
    1, 'fixture: one more message');
SELECT is((SELECT count(*)::int FROM pgmq.delete('ops_q', (SELECT array_agg(msg_id) FROM pgmq.q_ops_q WHERE message->>'n' = '7'))),
    1, 'delete(array): returns the ids it deleted');
SELECT is(pgmq.purge_queue('ops_q'), 1::bigint,
    'purge_queue: returns the number of purged messages (the hidden one)');
SELECT is((SELECT count(*)::int FROM pgmq.q_ops_q), 0,
    'purge_queue: the queue is empty afterwards');

-- =====================================================
-- GROUP 3: topic routing
-- =====================================================
SELECT ok(pgmq.validate_routing_key('logs.error'), 'validate_routing_key: a dotted key is valid');
SELECT throws_ok($$SELECT pgmq.validate_routing_key('logs.*')$$, 'P0001', NULL,
    'validate_routing_key: wildcards are rejected');
SELECT throws_ok($$SELECT pgmq.validate_routing_key('.logs')$$, 'P0001', NULL,
    'validate_routing_key: a leading dot is rejected');
SELECT throws_ok($$SELECT pgmq.validate_routing_key('logs..error')$$, 'P0001', NULL,
    'validate_routing_key: consecutive dots are rejected');
SELECT ok(pgmq.validate_topic_pattern('logs.#'), 'validate_topic_pattern: the # wildcard is valid');
SELECT throws_ok($$SELECT pgmq.validate_topic_pattern('logs.*#')$$, 'P0001', NULL,
    'validate_topic_pattern: adjacent wildcards are rejected');
SELECT throws_ok($$SELECT pgmq.validate_topic_pattern('logs.**')$$, 'P0001', NULL,
    'validate_topic_pattern: consecutive stars are rejected');

SELECT pgmq.create('ops_q2');
SELECT pgmq.bind_topic('logs.*', 'ops_q');
SELECT pgmq.bind_topic('logs.#', 'ops_q2');
SELECT throws_ok($$SELECT pgmq.bind_topic('x.*', 'no_such_queue')$$, 'P0001', NULL,
    'bind_topic: binding to an unknown queue is rejected');
SELECT set_eq($$SELECT queue_name FROM pgmq.test_routing('logs.error')$$, ARRAY['ops_q', 'ops_q2'],
    'test_routing: a single segment matches both * and # patterns');
SELECT set_eq($$SELECT queue_name FROM pgmq.test_routing('logs.api.error')$$, ARRAY['ops_q2'],
    'test_routing: several segments match the # pattern only');
SELECT is((SELECT count(*)::int FROM pgmq.list_topic_bindings('ops_q')), 1,
    'list_topic_bindings(queue): one binding for ops_q');
SELECT ok((SELECT count(*) FROM pgmq.list_topic_bindings()) >= 2,
    'list_topic_bindings(): lists every binding');
SELECT is(pgmq.send_topic('logs.error', '{"e":1}'), 2,
    'send_topic: returns the number of queues the message was delivered to');
SELECT is((SELECT count(*)::int FROM pgmq.q_ops_q WHERE message->>'e' = '1')
        + (SELECT count(*)::int FROM pgmq.q_ops_q2 WHERE message->>'e' = '1'),
    2, 'send_topic: the message landed in both bound queues');
SELECT is(pgmq.send_topic('nomatch.key', '{"e":2}'), 0,
    'send_topic: a key without bindings is delivered nowhere');
SELECT ok(pgmq.unbind_topic('logs.*', 'ops_q'), 'unbind_topic: true when a binding was removed');
SELECT ok(NOT pgmq.unbind_topic('logs.*', 'ops_q'), 'unbind_topic: false when nothing matched');

-- =====================================================
-- GROUP 4: insert-notify throttle
-- =====================================================
SELECT pgmq.enable_notify_insert('ops_q', 500);
SELECT is((SELECT throttle_interval_ms FROM pgmq.list_notify_insert_throttles() WHERE queue_name = 'ops_q'),
    500, 'enable_notify_insert: registers the throttle interval');
SELECT ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trigger_notify_queue_insert_listeners' AND tgrelid = 'pgmq.q_ops_q'::regclass),
    'enable_notify_insert: installs the insert trigger on the queue table');
SELECT pgmq.update_notify_insert('ops_q', 750);
SELECT is((SELECT throttle_interval_ms FROM pgmq.list_notify_insert_throttles() WHERE queue_name = 'ops_q'),
    750, 'update_notify_insert: changes the interval');
SELECT lives_ok($$SELECT pgmq.send('ops_q', '{"notify":true}')$$,
    'notify trigger: sending with the listener trigger installed succeeds');
SELECT pgmq.disable_notify_insert('ops_q');
SELECT ok(NOT EXISTS (SELECT 1 FROM pgmq.list_notify_insert_throttles() WHERE queue_name = 'ops_q'),
    'disable_notify_insert: removes the throttle');

-- =====================================================
-- GROUP 5: drop_queue
-- =====================================================
SELECT ok(pgmq.drop_queue('ops_q2'), 'drop_queue: returns true for an existing queue');
SELECT ok(NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE queue_name = 'ops_q2'), 'drop_queue: the queue is removed from pgmq.meta');
SELECT ok(NOT pgmq.drop_queue('ops_q2'), 'drop_queue: returns false for an unknown queue');
SELECT ok(pgmq.drop_queue('ops_q'), 'drop_queue: drops a queue that still has an archive and bindings');

SELECT * FROM finish();
ROLLBACK;
