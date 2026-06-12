-- Test pgmq install: a direct smoke test of the pgmq schema, its metadata
-- table, the core message functions, and the semantius_user grant. pgmq is
-- otherwise only exercised *indirectly* through the queues entity (0310); this
-- file asserts the install itself so a broken/missing 0160_pgmq surfaces here,
-- before 0310, independent of the queue wiring in 0170.
BEGIN;

SELECT plan(7);

-- Test 1: the pgmq schema exists
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgmq')),
    'pgmq schema should exist'
);

-- Test 2: the pgmq.meta queue-registry table exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'pgmq' AND table_name = 'meta'
    )),
    'pgmq.meta table should exist'
);

-- Test 3: pgmq.send (enqueue) exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmq' AND p.proname = 'send'
    )),
    'pgmq.send function should exist'
);

-- Test 4: pgmq.read (dequeue-with-vt) exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmq' AND p.proname = 'read'
    )),
    'pgmq.read function should exist'
);

-- Test 5: pgmq.create (create a queue) exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmq' AND p.proname = 'create'
    )),
    'pgmq.create function should exist'
);

-- Test 6: pgmq.drop_queue exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmq' AND p.proname = 'drop_queue'
    )),
    'pgmq.drop_queue function should exist'
);

-- Test 7: semantius_user has USAGE on the pgmq schema (granted by 0170_queue),
-- which the public.queue_* RPC wrappers rely on.
SELECT ok(
    has_schema_privilege('semantius_user', 'pgmq', 'USAGE'),
    'semantius_user should have USAGE on schema pgmq'
);

SELECT * FROM finish();
ROLLBACK;
