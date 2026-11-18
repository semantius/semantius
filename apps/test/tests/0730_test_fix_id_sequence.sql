-- =====================================================
-- public.fix_id_sequence (0730)
-- =====================================================
-- Pins the RPC an importer calls after writing explicit ids: it moves the id
-- sequence past max(id), never lowers it, answers NULL for keys without a
-- sequence, and is callable exactly by holders of the entity's edit_permission
-- who see the entity in the catalog, with an unknown table and a denied one
-- looking alike to non-admins.
--
-- The lock-timeout path (90232) needs a second session holding a conflicting
-- lock, which one pgTAP transaction cannot produce; pgdocker/pg-ext-lifecycle.sh
-- section 1f proves it. Here only the 2 s bound itself is pinned.
--
-- An is_a entity whose base the caller does not see is hidden in the catalog
-- even from a holder of its own edit permission, and answers as an unknown
-- table does: the 42501, not the NULL of a key without a sequence.
--
-- Fixtures: user1 holds the User role only, user2 is Northwind Sales
-- (nwind:manage), user3 is the administrator. fixseq_base is a typeid entity
-- viewed and edited with admin, fixseq_sub an is_a entity below it viewed with
-- public:read and edited with nwind:manage.
BEGIN;

SELECT plan(21);

-- A fresh transaction carries no claims, so this is an unauthenticated caller.
SET ROLE semantius_user;
SELECT throws_ok($$SELECT public.fix_id_sequence('no_such_table')$$, '42501', NULL,
    'unauthenticated: refused');
RESET ROLE;

SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES
    ('fixseq_test',  'fixseq_test',  'Fixseq Test',  'Fixseq Tests',  'fix_id_sequence test table', 1, 'public:read', 'nwind:manage', 'id', 'label'),
    ('fixseq_empty', 'fixseq_empty', 'Fixseq Empty', 'Fixseq Empties', 'fix_id_sequence empty table', 1, 'public:read', 'nwind:manage', 'id', 'label');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('fixseq_unmanaged', 'fixseq_unmanaged', 'Fixseq Unmanaged', 'Fixseq Unmanaged', 'fix_id_sequence entity without a table', 1, 'public:read', 'admin', 'id', 'label', FALSE);
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_type, id_prefix)
VALUES ('fixseq_base', 'fixseq_base', 'Fixseq Base', 'Fixseq Bases', 'fix_id_sequence base only an administrator sees', 1, 'admin', 'admin', 'typeid', 'fixseqbase');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_type, id_prefix, id_refentity)
VALUES ('fixseq_sub', 'fixseq_sub', 'Fixseq Sub', 'Fixseq Subs', 'fix_id_sequence is_a entity under a hidden base', 1, 'public:read', 'nwind:manage', 'is_a', 'fixseqsub', 'fixseq_base');

-- =====================================================
-- An import with explicit ids, then the repair
-- =====================================================
SELECT authenticate_as('user2');
INSERT INTO fixseq_test (id, label) SELECT g, 'imported ' || g FROM generate_series(1, 5) g;

SELECT is(public.fix_id_sequence('fixseq_test'), 6::bigint,
    'returns the id after the highest imported one');
SELECT ok(EXISTS (SELECT 1 FROM pg_locks
                  WHERE relation = 'public.fixseq_test'::regclass
                    AND pid = pg_backend_pid()
                    AND mode = 'ShareRowExclusiveLock'
                    AND granted),
    'the table lock is held by the calling transaction');
SELECT is(public.fix_id_sequence('fixseq_test'), 6::bigint,
    'a second call changes nothing');
SELECT lives_ok($$INSERT INTO fixseq_test (label) VALUES ('ordinary')$$,
    'an ordinary insert after the repair does not collide');
SELECT is((SELECT id FROM fixseq_test WHERE label = 'ordinary'), 6::bigint,
    'the ordinary insert took the id the call returned');

-- A sequence that has already handed out ids (is_called) continues after them.
INSERT INTO fixseq_test (label) VALUES ('seq 7'), ('seq 8');
INSERT INTO fixseq_test (id, label) VALUES (20, 'imported 20');
SELECT is(public.fix_id_sequence('fixseq_test'), 21::bigint,
    'an explicit id above the sequence moves it past that id');
INSERT INTO fixseq_test (label) VALUES ('seq 21');
DELETE FROM fixseq_test WHERE id >= 20;
SELECT is(public.fix_id_sequence('fixseq_test'), 22::bigint,
    'deleting the highest rows does not lower a sequence that already issued their ids');

-- A sequence set ahead of max(id) and not yet called stays where it is.
RESET ROLE;
SELECT setval(pg_get_serial_sequence('public.fixseq_test', 'id'), 100, false);
SELECT authenticate_as('user2');
SELECT is(public.fix_id_sequence('fixseq_test'), 100::bigint,
    'a sequence ahead of max(id) is never lowered');

-- =====================================================
-- Tables without a sequence to fix
-- =====================================================
SELECT authenticate_as('user3');
SELECT is(public.fix_id_sequence('fixseq_empty'), 1::bigint,
    'an empty table with a fresh sequence: 1');
SELECT is(public.fix_id_sequence('permissions'), NULL::bigint,
    'a text key has no sequence: NULL');
SELECT is(public.fix_id_sequence('fixseq_unmanaged'), NULL::bigint,
    'an entity whose table does not exist: NULL, not 42P01');

-- =====================================================
-- Refusals
-- =====================================================
SELECT throws_ok($$SELECT public.fix_id_sequence('no_such_table')$$,
    '90231', 'Table ${table} is not an entity',
    'an administrator is told the table is not an entity');
SELECT is(catch_error_hint($$SELECT public.fix_id_sequence('no_such_table')$$),
    '{"table": "no_such_table"}'::jsonb,
    'the 90231 hint carries the table');

-- user1 holds neither nwind:manage nor admin.
SELECT authenticate_as('user1');
SELECT throws_ok($$SELECT public.fix_id_sequence('no_such_table')$$,
    '42501', 'Permission denied: cannot fix the id sequence of ${table}',
    'a non-admin gets 42501 for an unknown table');
SELECT throws_ok($$SELECT public.fix_id_sequence('fixseq_test')$$,
    '42501', 'Permission denied: cannot fix the id sequence of ${table}',
    'and the same 42501 for a table it may not edit');
SELECT is(catch_error_hint($$SELECT public.fix_id_sequence('no_such_table')$$),
    '{"code": "90106", "table": "no_such_table"}'::jsonb,
    'the unknown-table refusal carries hint.code 90106');
SELECT is(catch_error_hint($$SELECT public.fix_id_sequence('fixseq_test')$$),
    '{"code": "90106", "table": "fixseq_test"}'::jsonb,
    'the denied-table refusal carries the same hint.code 90106');

-- user2 holds nwind:manage, the edit permission of fixseq_sub, but not admin,
-- which its base needs.
SELECT authenticate_as('user2');
SELECT throws_ok($$SELECT public.fix_id_sequence('fixseq_sub')$$,
    '42501', 'Permission denied: cannot fix the id sequence of ${table}',
    'a holder of the edit permission of an is_a entity whose base it does not see gets the 42501 of an unknown table');

-- =====================================================
-- Grants and settings
-- =====================================================
RESET ROLE;
SELECT ok(has_function_privilege('semantius_user', 'public.fix_id_sequence(text)', 'EXECUTE'),
    'the request role may execute it');
SELECT ok((SELECT 'lock_timeout=2s' = ANY (p.proconfig)
           FROM pg_proc p WHERE p.oid = 'public.fix_id_sequence(text)'::regprocedure),
    'the lock wait is capped at 2 s');

SELECT * FROM finish();
ROLLBACK;
