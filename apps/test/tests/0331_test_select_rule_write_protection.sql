-- Test: select_rule must gate UPDATE and DELETE, not only SELECT.
--
-- A select_rule is the ABAC row-visibility mechanism (FOR SELECT RLS policy, see
-- 0180_computed_validation.sql). The INSERT/UPDATE/DELETE policies, however, are
-- keyed only on edit_permission (see update_entity_policies in 0070_dd_functions.sql).
-- This test verifies the security invariant a user would reasonably expect:
--
--     a user who holds edit_permission but CANNOT SEE a row (because select_rule
--     hides it) must not be able to UPDATE or DELETE that row.
--
-- It exercises several statement shapes because PostgreSQL only applies SELECT
-- policies to an UPDATE/DELETE when the statement reads columns (WHERE / RETURNING).
-- Unqualified bulk statements are the dangerous case.
--
-- Fixtures (0030_seed.sql): user2 (id 1002) holds the 'sales:manage' permission;
-- user1 (id 1001) is a plain user; user3 is admin (auto-granted every permission).
BEGIN;

SELECT plan(11);

-- =====================================================
-- SETUP (as admin): entity whose rows are visible only to their owner (or admin),
-- but editable by anyone holding 'sales:manage'.
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    view_permission, edit_permission, select_rule
) VALUES (
    'test_abac_write', 'test_abac_write_item', 'ABAC Write Item', 'ABAC Write Items',
    'Verifies select_rule restricts writes/deletes, not just reads',
    'public:read', 'sales:manage',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb
);

INSERT INTO fields (
    table_name, field_name, title, format, field_order, input_type, width,
    reference_table, reference_delete_mode
) VALUES (
    'test_abac_write', 'assigned_to', 'Assigned To', 'reference', 20, 'default', 'default',
    'users', 'clear'
);

-- Hidden row owned by user1 (invisible to user2); visible row owned by user2.
INSERT INTO test_abac_write (label, assigned_to) VALUES
    ('hidden-row', 1001),
    ('owned-row',  1002);

-- =====================================================
-- SANITY (as user2): select_rule visibility works.
-- =====================================================
SELECT authenticate_as('user2');

SELECT is(
    (SELECT count(*)::int FROM test_abac_write),
    1,
    'sanity: user2 (editor) sees only their own row via select_rule'
);

SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE assigned_to = 1001),
    0,
    'sanity: the user1-owned row is hidden from user2 by select_rule'
);

-- =====================================================
-- POSITIVE CONTROL: user2 CAN edit their own (visible) row.
-- Proves the write capability exists, so a 0-effect write below is due to
-- row invisibility, not a missing edit_permission.
-- =====================================================
SAVEPOINT sp_pc;
SELECT authenticate_as('user2');
UPDATE test_abac_write SET label = 'owned-edit' WHERE assigned_to = 1002;
SELECT authenticate_as('user3');
SELECT is(
    (SELECT label FROM test_abac_write WHERE assigned_to = 1002)::text,
    'owned-edit',
    'positive control: editor can modify their own (visible) row'
);
ROLLBACK TO sp_pc;

-- =====================================================
-- A: qualified UPDATE (WHERE, no RETURNING) must not modify a hidden row.
-- =====================================================
SAVEPOINT sp_a;
SELECT authenticate_as('user2');
UPDATE test_abac_write SET label = 'hacked-A' WHERE assigned_to = 1001;
SELECT authenticate_as('user3');
SELECT is(
    (SELECT label FROM test_abac_write WHERE assigned_to = 1001)::text,
    'hidden-row',
    'A: qualified UPDATE by an editor must NOT modify a select_rule-hidden row'
);
ROLLBACK TO sp_a;

-- =====================================================
-- B: unqualified UPDATE (no WHERE) must not modify a hidden row.
-- =====================================================
SAVEPOINT sp_b;
SELECT authenticate_as('user2');
UPDATE test_abac_write SET label = 'hacked-B';
SELECT authenticate_as('user3');
SELECT is(
    (SELECT label FROM test_abac_write WHERE assigned_to = 1001)::text,
    'hidden-row',
    'B: unqualified UPDATE by an editor must NOT modify a select_rule-hidden row'
);
ROLLBACK TO sp_b;

-- =====================================================
-- C: qualified DELETE (WHERE, no RETURNING) must not remove a hidden row.
-- =====================================================
SAVEPOINT sp_c;
SELECT authenticate_as('user2');
DELETE FROM test_abac_write WHERE assigned_to = 1001;
SELECT authenticate_as('user3');
SELECT ok(
    EXISTS (SELECT 1 FROM test_abac_write WHERE assigned_to = 1001),
    'C: qualified DELETE by an editor must NOT remove a select_rule-hidden row'
);
ROLLBACK TO sp_c;

-- =====================================================
-- D: unqualified DELETE (no WHERE) must not remove a hidden row.
-- =====================================================
SAVEPOINT sp_d;
SELECT authenticate_as('user2');
DELETE FROM test_abac_write;
SELECT authenticate_as('user3');
SELECT ok(
    EXISTS (SELECT 1 FROM test_abac_write WHERE assigned_to = 1001),
    'D: unqualified DELETE by an editor must NOT remove a select_rule-hidden row'
);
ROLLBACK TO sp_d;

-- =====================================================
-- E: DELETE ... RETURNING on a hidden row must affect 0 rows.
-- =====================================================
SAVEPOINT sp_e;
SELECT authenticate_as('user2');
WITH d AS (
    DELETE FROM test_abac_write WHERE assigned_to = 1001 RETURNING 1
)
SELECT is(count(*)::int, 0,
    'E: DELETE ... RETURNING on a hidden row affects 0 rows'
) FROM d;
ROLLBACK TO sp_e;

-- =====================================================
-- F: UPDATE ... RETURNING on a hidden row must affect 0 rows.
-- =====================================================
SAVEPOINT sp_f;
SELECT authenticate_as('user2');
WITH u AS (
    UPDATE test_abac_write SET label = 'hacked-F' WHERE assigned_to = 1001 RETURNING 1
)
SELECT is(count(*)::int, 0,
    'F: UPDATE ... RETURNING on a hidden row affects 0 rows'
) FROM u;
ROLLBACK TO sp_f;

-- =====================================================
-- G: UPDATE ... WHERE TRUE — "qualified" but reads no column, so PostgreSQL does NOT
-- apply the SELECT policy. The protective axis is "reads-a-column", not "qualified"
-- (spec v2 A4). Must still not modify a hidden row.
-- =====================================================
SAVEPOINT sp_g;
SELECT authenticate_as('user2');
UPDATE test_abac_write SET label = 'hacked-G' WHERE TRUE;
SELECT authenticate_as('user3');
SELECT is(
    (SELECT label FROM test_abac_write WHERE assigned_to = 1001)::text,
    'hidden-row',
    'G: UPDATE ... WHERE TRUE (reads no column) must NOT modify a select_rule-hidden row'
);
ROLLBACK TO sp_g;

-- =====================================================
-- H: DELETE ... WHERE TRUE — same axis: reads no column, SELECT policy not applied.
-- =====================================================
SAVEPOINT sp_h;
SELECT authenticate_as('user2');
DELETE FROM test_abac_write WHERE TRUE;
SELECT authenticate_as('user3');
SELECT ok(
    EXISTS (SELECT 1 FROM test_abac_write WHERE assigned_to = 1001),
    'H: DELETE ... WHERE TRUE (reads no column) must NOT remove a select_rule-hidden row'
);
ROLLBACK TO sp_h;

SELECT * FROM finish();
ROLLBACK;
