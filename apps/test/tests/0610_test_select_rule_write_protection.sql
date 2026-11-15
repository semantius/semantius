-- Test: select_rule must gate UPDATE and DELETE, not only SELECT.
--
-- A select_rule is the ABAC row-visibility mechanism (FOR SELECT RLS policy, see
-- 0210_computed_validation.sql). The INSERT/UPDATE/DELETE policies, however, are
-- keyed only on edit_permission (see update_entity_policies in 0160_dd_functions.sql).
-- This test verifies the security invariant a user would reasonably expect:
--
--     a user who holds edit_permission but CANNOT SEE a row (because select_rule
--     hides it) must not be able to UPDATE or DELETE that row.
--
-- It exercises several statement shapes because PostgreSQL only applies SELECT
-- policies to an UPDATE/DELETE when the statement reads columns (WHERE / RETURNING).
-- Unqualified bulk statements are the dangerous case.
--
-- A second part covers the other side of the same policies: a reader who sees
-- a row through the rule but lacks the edit permission, and what an editor may
-- insert or move around the rule.
--
-- Fixtures: user2 (id 1002) holds 'nwind:manage' via the Northwind Sales role (apps/nwind);
-- user1 (id 1001) is a plain user; user3 is admin (auto-granted every permission).
BEGIN;

SELECT plan(41);

-- =====================================================
-- SETUP (as admin): entity whose rows are visible only to their owner (or admin),
-- but editable by anyone holding 'nwind:manage'.
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    view_permission, edit_permission, select_rule, module_id
) VALUES (
    'test_abac_write', 'test_abac_write_item', 'ABAC Write Item', 'ABAC Write Items',
    'Verifies select_rule restricts writes/deletes, not just reads',
    'public:read', 'nwind:manage',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb,
    1
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

-- =====================================================
-- READER WITHOUT THE EDIT PERMISSION
-- =====================================================
-- UPDATE and DELETE are allowed by edit_permission AND the row rule, so seeing
-- a row through the rule is not enough to write it. user1 holds neither
-- nwind:manage nor admin and sees exactly the row assigned to it (the label
-- 'hidden-row' only says the row is hidden from user2). Every attempt is read
-- back as the owner, which bypasses row security, so a write that was filtered
-- out silently is told apart from one that never ran.
SELECT authenticate_as('user1');
SELECT is(
    (SELECT string_agg(label, ',') FROM test_abac_write),
    'hidden-row',
    'reader: user1 sees the row assigned to it through the rule, and only that one');

SAVEPOINT sp_r1;
SELECT authenticate_as('user1');
WITH u AS (
    UPDATE test_abac_write SET label = 'reader-edit'
     WHERE assigned_to = (SELECT id FROM users WHERE external_id = 'user1') RETURNING 1
)
SELECT is(count(*)::int, 0,
    'reader: UPDATE of a row it sees but may not edit affects 0 rows'
) FROM u;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT label FROM test_abac_write WHERE assigned_to = (SELECT id FROM users WHERE external_id = 'user1')),
    'hidden-row',
    'reader: and the row is unchanged for the owner');
ROLLBACK TO sp_r1;

SAVEPOINT sp_r2;
SELECT authenticate_as('user1');
WITH d AS (
    DELETE FROM test_abac_write
     WHERE assigned_to = (SELECT id FROM users WHERE external_id = 'user1') RETURNING 1
)
SELECT is(count(*)::int, 0,
    'reader: DELETE of a row it sees but may not edit affects 0 rows'
) FROM d;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT ok(
    EXISTS (SELECT 1 FROM test_abac_write WHERE assigned_to = (SELECT id FROM users WHERE external_id = 'user1')),
    'reader: and the row is still there for the owner');
ROLLBACK TO sp_r2;

-- INSERT is gated by edit_permission alone, so the reader is refused outright
-- rather than filtered.
SAVEPOINT sp_r3;
SELECT authenticate_as('user1');
SELECT throws_ok(
    $$ INSERT INTO test_abac_write (label, assigned_to)
       VALUES ('reader-insert', (SELECT id FROM users WHERE external_id = 'user1')) $$,
    '42501',
    'new row violates row-level security policy for table "test_abac_write"',
    'reader: INSERT of a row the rule would show it is refused for lack of the edit permission');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'reader-insert'),
    0,
    'reader: and nothing was stored for the owner');
ROLLBACK TO sp_r3;

-- =====================================================
-- INSERT OUTSIDE THE CALLER'S OWN RULE
-- =====================================================
-- The INSERT policy carries edit_permission only: there is no per-row rule on
-- an insert, so an editor may store a row that the rule then hides from it.
SAVEPOINT sp_i1;
SELECT authenticate_as('user2');
SELECT lives_ok(
    $$ INSERT INTO test_abac_write (label, assigned_to)
       VALUES ('moved-in', (SELECT id FROM users WHERE external_id = 'user1')) $$,
    'insert outside the rule: an editor may insert a row assigned to somebody else');
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'moved-in'),
    0,
    'insert outside the rule: and cannot read the row back through the rule');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'moved-in'),
    1,
    'insert outside the rule: the owner finds the row stored');
ROLLBACK TO sp_i1;

-- With RETURNING, PostgreSQL also holds the new row to the SELECT policy, which
-- is the rule. The row being written passes that one check, so a client that
-- asks for the created row back (PostgREST's return=representation) gets it,
-- as it gets the insert without asking; afterward the rule hides the row.
SAVEPOINT sp_i2;
SELECT authenticate_as('user2');
SELECT lives_ok(
    $$ INSERT INTO test_abac_write (label, assigned_to)
       VALUES ('moved-in', (SELECT id FROM users WHERE external_id = 'user1')) RETURNING id $$,
    'insert outside the rule with RETURNING: the row is stored and handed back');
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'moved-in'),
    0,
    'insert outside the rule with RETURNING: and the editor cannot read it afterward');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'moved-in'),
    1,
    'insert outside the rule with RETURNING: the owner finds the row stored');
ROLLBACK TO sp_i2;

-- =====================================================
-- UPDATE THAT MOVES A ROW OUT OF THE CALLER'S OWN RULE
-- =====================================================
-- The UPDATE policy's WITH CHECK is edit_permission only, so there is no
-- post-image rule and a write may move a row out of its own rule. The old row
-- still has to pass the rule (the USING clause), so the editor touches only
-- the row it sees, and once the row has left it cannot write it again.
SAVEPOINT sp_m1;
SELECT authenticate_as('user2');
SELECT lives_ok(
    $$ UPDATE test_abac_write SET assigned_to = (SELECT id FROM users WHERE external_id = 'user1') $$,
    'move out of the rule: an editor may reassign its own row (a statement that reads no column)');
SELECT is(
    (SELECT count(*)::int FROM test_abac_write),
    0,
    'move out of the rule: and no longer sees it');
WITH u AS (
    UPDATE test_abac_write SET label = 'second-edit' RETURNING 1
)
SELECT is(count(*)::int, 0,
    'move out of the rule: and its next write affects 0 rows'
) FROM u;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(label || ':' || (assigned_to = (SELECT id FROM users WHERE external_id = 'user1'))::text,
                       ',' ORDER BY label) FROM test_abac_write),
    'hidden-row:true,owned-row:true',
    'move out of the rule: the owner finds the row reassigned and unedited, and the other row untouched');
ROLLBACK TO sp_m1;

-- The same move with a WHERE on a column of the table, the shape a client that
-- addresses a record by its key uses. PostgreSQL then holds the new row to the
-- SELECT policy as well, which is the rule.
SAVEPOINT sp_m2;
SELECT authenticate_as('user2');
SELECT lives_ok(
    $$ UPDATE test_abac_write SET assigned_to = (SELECT id FROM users WHERE external_id = 'user1')
        WHERE label = 'owned-row' $$,
    'move out of the rule: an editor may reassign its own row (a statement that reads a column)');
SELECT is(
    (SELECT count(*)::int FROM test_abac_write),
    0,
    'move out of the rule: and no longer sees the row it moved with a WHERE');
ROLLBACK TO sp_m2;

-- The same with RETURNING: the statement hands back the row it wrote, once.
SAVEPOINT sp_m3;
SELECT authenticate_as('user2');
WITH u AS (
    UPDATE test_abac_write SET assigned_to = (SELECT id FROM users WHERE external_id = 'user1')
     WHERE label = 'owned-row' RETURNING label
)
SELECT is((SELECT string_agg(label, ',') FROM u), 'owned-row',
    'move out of the rule: a move with RETURNING hands back the row it wrote');
SELECT is(
    (SELECT count(*)::int FROM test_abac_write),
    0,
    'move out of the rule: and the row is hidden once the statement has ended');
ROLLBACK TO sp_m3;

-- =====================================================
-- WHAT LETS THE WRITTEN ROW PASS CANNOT BE FORGED
-- =====================================================
-- The row being written passes the rule through a token in the setting
-- app.row_move. A client that runs SQL can write that setting, so the token is
-- made with a secret the request role cannot read: a value the client chose
-- opens nothing, and the token of one row does not open another.
SAVEPOINT sp_f1;
SELECT authenticate_as('user2');
SELECT set_config('app.row_move', 'test_abac_write', true);
SELECT is(
    (SELECT count(*)::int FROM test_abac_write WHERE label = 'hidden-row'),
    0,
    'forgery: a value the client wrote into app.row_move opens no hidden row');
ROLLBACK TO sp_f1;

-- An INSERT is marked before PostgreSQL finds a key conflict. An insert under
-- the key of a hidden row, which ON CONFLICT DO NOTHING then drops, must not
-- let the same statement read that row.
SAVEPOINT sp_f2;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT set_config('test.hidden_id', (SELECT id::text FROM test_abac_write WHERE label = 'hidden-row'), true);
SELECT authenticate_as('user2');
-- The LATERAL reference makes the insert run before the table is read.
WITH i AS (
    INSERT INTO test_abac_write (id, label, assigned_to)
    VALUES (current_setting('test.hidden_id')::bigint, 'probe', (SELECT id FROM users WHERE external_id = 'user2'))
    ON CONFLICT DO NOTHING
    RETURNING 1
)
SELECT is(
    (SELECT count(*)::int
       FROM (SELECT count(*) AS n FROM i OFFSET 0) done
      CROSS JOIN LATERAL (SELECT 1 FROM test_abac_write t
                           WHERE t.id = current_setting('test.hidden_id')::bigint AND done.n >= 0) seen),
    0,
    'forgery: an insert under the key of a hidden row does not let its statement read that row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(label, ',' ORDER BY label) FROM test_abac_write),
    'hidden-row,owned-row',
    'forgery: and the hidden row is as it was');
ROLLBACK TO sp_f2;

-- The same holds for the entities that ship with a rule. modules shows a
-- caller the modules whose view permission it holds, and user_bookmarks a
-- caller its own bookmarks: user1 holds no nwind:view and owns no bookmark.
SAVEPOINT sp_f3;
SELECT authenticate_as('user2');
INSERT INTO user_bookmarks (title, url) VALUES ('Forgery Probe', 'https://example.com');
SELECT authenticate_as('user1');
SELECT set_config('app.row_move', 'modules', true);
SELECT is(
    (SELECT count(*)::int FROM modules WHERE module_slug = 'nwind'),
    0,
    'forgery: a value written into app.row_move opens no hidden module');
SELECT is(
    (SELECT count(*)::int FROM user_bookmarks WHERE title = 'Forgery Probe'),
    0,
    'forgery: nor the bookmark of another user');
ROLLBACK TO sp_f3;

-- The secret is created when a rule is saved. Should it be missing, the next
-- rule saved, or the next row written, creates it again, and it then stays
-- what it is.
SAVEPOINT sp_f4;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
DELETE FROM _settings WHERE name = 'row_move_secret';
SELECT matches(common.row_move_secret(), '^[0-9a-f]{64}$',
    'the secret is created again when it is missing: 64 hexadecimal characters');
SELECT is(common.row_move_secret(), (SELECT value FROM _settings WHERE name = 'row_move_secret'),
    'and it is the value stored in _settings from then on');
SELECT is(common.row_move_matches('test_abac_write', NULL), FALSE,
    'a row without a key is never the row being written');
SELECT is(
    has_function_privilege('semantius_user', 'common.row_move_secret()', 'EXECUTE')
    OR has_function_privilege('semantius_user', 'common.row_move_matches(text, text)', 'EXECUTE')
    OR has_function_privilege('semantius_user', 'common.row_move_token(text, text, text, text)', 'EXECUTE'),
    FALSE,
    'the request role can execute none of the functions that read or use the secret');
ROLLBACK TO sp_f4;

SELECT * FROM finish();
ROLLBACK;
