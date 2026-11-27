-- Test: the row a caller may read must gate UPDATE and DELETE, not only SELECT.
--
-- A select_rule is the ABAC row-visibility mechanism (FOR SELECT RLS policy, see
-- 0210_computed_validation.sql). The INSERT policy and the WITH CHECK of UPDATE
-- are keyed on edit_permission only. This test verifies the security invariant a
-- user would reasonably expect:
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
-- insert or move around the rule. The last two parts hold an entity without a
-- rule to the same invariant, where the row a caller may read is the one its
-- view permission lets it read, and follow its UPDATE and DELETE policies
-- through every change that rebuilds them.
--
-- Fixtures: user2 (id 1002) holds 'nwind:manage' via the Northwind Sales role (apps/nwind);
-- user1 (id 1001) is a plain user; user3 is admin (auto-granted every permission).
BEGIN;

SELECT plan(96);

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
-- (docs/authorization.md A4). Must still not modify a hidden row.
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
-- made with a secret: a value the client chose without it opens nothing, and
-- the token of one row does not open another. Behind PostgREST a value the
-- client writes opens nothing. A session that runs its own SQL, a bearer
-- session, can read the secret from app.row_move_secret once a write of its
-- transaction has kept it there, and get past every select_rule. Before bearer
-- sessions are enabled, the marking trigger has to read the secret from
-- _settings on every row through the definer function and keep it in no
-- setting, and the secret in _settings has to be replaced: it is never rotated,
-- so a secret read once stays valid.
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

-- =====================================================
-- THE SAME MOVE IN A FAMILY
-- =====================================================
-- The record of an is_a or has_a entity is written through its view: an
-- INSTEAD OF trigger hands it to the entity's write routine, which writes the
-- base table and <entity>_ext. The rule and the two triggers that mark the row
-- being written sit on <entity>_ext. A write that moves the record out of the
-- writer's own rule must go through there as on a plain table, the record is
-- hidden afterward, and a forged marker opens nothing.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_column,
                      view_permission, edit_permission)
VALUES ('rmf_parties', 'Rmf Party', 'Rmf Parties', 1, 'typeid', 'rmfp', 'id', 'public:read', 'nwind:manage');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, edit_permission, select_rule)
VALUES ('rmf_orgs', 'Rmf Org', 'Rmf Orgs', 1, 'is_a', 'rmfo', 'rmf_parties', 'public:read', 'nwind:manage',
        '{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}'::jsonb);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                      view_permission, edit_permission, select_rule)
VALUES ('rmf_vendors', 'Rmf Vendor', 'Rmf Vendors', 1, 'has_a', 'rmf_parties', 'public:read', 'nwind:manage',
        '{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('rmf_orgs',    'assigned_to', 'Assigned To', 'reference', 30, 'users', 'clear'),
       ('rmf_vendors', 'assigned_to', 'Assigned To', 'reference', 30, 'users', 'clear');

-- The records, written by the owner: one of user2 and one of user1 per entity.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO rmf_orgs (label, assigned_to) VALUES ('org-owned', 1002), ('org-hidden', 1001);
INSERT INTO rmf_vendors (label, assigned_to) VALUES ('ven-owned', 1002), ('ven-hidden', 1001);

SELECT authenticate_as('user2');
SELECT is(
    (SELECT string_agg(label, ',' ORDER BY label) FROM rmf_orgs),
    'org-owned',
    'family, is_a: the editor sees its own record and not the other');
SELECT lives_ok(
    $$ UPDATE rmf_orgs SET assigned_to = (SELECT id FROM users WHERE external_id = 'user1')
        WHERE label = 'org-owned' $$,
    'family, is_a: an editor may reassign its own record through the view');
SELECT is(
    (SELECT count(*)::int FROM rmf_orgs),
    0,
    'family, is_a: and no longer sees it');
SELECT set_config('app.row_move', 'rmf_orgs_ext', true);
SELECT is(
    (SELECT count(*)::int FROM rmf_orgs WHERE label = 'org-hidden'),
    0,
    'family, is_a: a value the client wrote into app.row_move opens no hidden record');
SELECT set_config('app.row_move', '', true);

SELECT is(
    (SELECT string_agg(label, ',' ORDER BY label) FROM rmf_vendors),
    'ven-owned',
    'family, has_a: the editor sees its own record and not the other');
SELECT lives_ok(
    $$ UPDATE rmf_vendors SET assigned_to = (SELECT id FROM users WHERE external_id = 'user1')
        WHERE label = 'ven-owned' $$,
    'family, has_a: an editor may reassign its own record through the view');
SELECT is(
    (SELECT count(*)::int FROM rmf_vendors),
    0,
    'family, has_a: and no longer sees it');
SELECT set_config('app.row_move', 'rmf_vendors_ext', true);
SELECT is(
    (SELECT count(*)::int FROM rmf_vendors WHERE label = 'ven-hidden'),
    0,
    'family, has_a: a value the client wrote into app.row_move opens no hidden record');
SELECT set_config('app.row_move', '', true);

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(label || ':' || assigned_to, ',' ORDER BY label) FROM rmf_orgs),
    'org-hidden:1001,org-owned:1001',
    'family, is_a: the owner finds the record reassigned and the other untouched');
SELECT is(
    (SELECT string_agg(label || ':' || assigned_to, ',' ORDER BY label) FROM rmf_vendors),
    'ven-hidden:1001,ven-owned:1001',
    'family, has_a: the owner finds the record reassigned and the other untouched');

-- =====================================================
-- AN ENTITY WITHOUT A RULE
-- =====================================================
-- Without a select_rule, a caller may read the rows of an entity when it holds
-- the view permission, and UPDATE and DELETE check that permission next to the
-- edit permission. The statements below read no column of the table, so
-- PostgreSQL does not hold the rows they touch to the SELECT policy: the USING
-- of UPDATE and DELETE is all that stands between a holder of the edit
-- permission alone and every row. No permission_hierarchy row joins the two
-- fixture permissions, so holding one says nothing about the other.
--
-- pg_temp.rows_written runs a statement as the calling role and returns the
-- number of rows it wrote, or the SQLSTATE when it raised, so a refusal where a
-- silent 0 is expected shows in the assertion. Every attempt is read back as
-- the owner, which bypasses row security.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.rows_written(p_sql TEXT) RETURNS TEXT AS $$
DECLARE
    v_rows BIGINT;
BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows::text;
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

SELECT authenticate_as('user3');
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('nrw:view', 'View permission of the no-rule write fixture', 1),
       ('nrw:edit', 'Edit permission of the no-rule write fixture', 1);
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      view_permission, edit_permission, module_id)
VALUES ('test_norule_write', 'test_norule_write_item', 'No-Rule Write Item', 'No-Rule Write Items',
        'Verifies that the view permission gates UPDATE and DELETE of an entity without a select_rule',
        'nrw:view', 'nrw:edit', 1);

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO test_norule_write (label) VALUES ('r1'), ('r2'), ('r3');
INSERT INTO user_permissions (user_id, permission_name, granted_by)
SELECT u1.id, 'nrw:edit', u3.id
  FROM users u1, users u3
 WHERE u1.external_id = 'user1' AND u3.external_id = 'user3';

SELECT is(
    (SELECT qual FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write'
        AND policyname = 'test_norule_write_update_policy'),
    '(( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''nrw:view''::text) AS has_permission))',
    'no rule: the UPDATE policy reaches a row through the edit permission and the view permission, each in a sub-select');
SELECT is(
    (SELECT with_check FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write'
        AND policyname = 'test_norule_write_update_policy'),
    '( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission)',
    'no rule: the new row of an UPDATE is held to the edit permission alone');
SELECT is(
    (SELECT qual FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write'
        AND policyname = 'test_norule_write_delete_policy'),
    '(( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''nrw:view''::text) AS has_permission))',
    'no rule: the DELETE policy reaches a row through the edit permission and the view permission');
SELECT is(
    (SELECT with_check FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write'
        AND policyname = 'test_norule_write_insert_policy'),
    '( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission)',
    'no rule: an inserted row is held to the edit permission alone');

SELECT authenticate_as('user1');
SELECT is(
    ARRAY[rbac.has_permission('nrw:edit'), rbac.has_permission('nrw:view')],
    ARRAY[true, false],
    'no rule: user1 holds the edit permission and not the view permission');
SELECT is(
    (SELECT count(*)::int FROM test_norule_write),
    0,
    'no rule: and reads none of the rows');

-- Edit permission without the view permission: every statement shape that
-- reads no column writes nothing. Each runs on its own savepoint, so a shape
-- that did write cannot hide a later one by leaving it no row to write.
SAVEPOINT sp_n1a;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ UPDATE test_norule_write SET label = 'x' $$), '0',
    'edit without view: UPDATE t SET label = ''x'' writes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after UPDATE t SET label = ''x'' the owner finds every row unchanged');
ROLLBACK TO sp_n1a;

SAVEPOINT sp_n1b;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ UPDATE test_norule_write SET label = 'x' WHERE true $$), '0',
    'edit without view: UPDATE ... WHERE true writes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after UPDATE ... WHERE true the owner finds every row unchanged');
ROLLBACK TO sp_n1b;

SAVEPOINT sp_n1c;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ UPDATE test_norule_write SET label = 'x' RETURNING 1 $$), '0',
    'edit without view: UPDATE ... RETURNING 1 writes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after UPDATE ... RETURNING 1 the owner finds every row unchanged');
ROLLBACK TO sp_n1c;

SAVEPOINT sp_n1d;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ DELETE FROM test_norule_write $$), '0',
    'edit without view: DELETE FROM t deletes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after DELETE FROM t the owner finds every row there');
ROLLBACK TO sp_n1d;

SAVEPOINT sp_n1e;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ DELETE FROM test_norule_write WHERE true $$), '0',
    'edit without view: DELETE ... WHERE true deletes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after DELETE ... WHERE true the owner finds every row there');
ROLLBACK TO sp_n1e;

SAVEPOINT sp_n1f;
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ DELETE FROM test_norule_write RETURNING 1 $$), '0',
    'edit without view: DELETE ... RETURNING 1 deletes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is((SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write), 'r1,r2,r3',
    'edit without view: after DELETE ... RETURNING 1 the owner finds every row there');
ROLLBACK TO sp_n1f;

-- INSERT is held to the edit permission alone, without the view permission.
SAVEPOINT sp_n2;
SELECT authenticate_as('user1');
SELECT lives_ok(
    $$ INSERT INTO test_norule_write (label) VALUES ('edit-insert') $$,
    'edit without view: INSERT is allowed');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT count(*)::int FROM test_norule_write WHERE label = 'edit-insert'),
    1,
    'edit without view: and the owner finds the inserted row');
ROLLBACK TO sp_n2;

-- Control: user2 holds neither permission.
SAVEPOINT sp_n3;
SELECT authenticate_as('user2');
SELECT is(pg_temp.rows_written($$ UPDATE test_norule_write SET label = 'x' $$), '0',
    'neither permission: UPDATE t SET label = ''x'' writes no row');
SELECT is(pg_temp.rows_written($$ DELETE FROM test_norule_write $$), '0',
    'neither permission: DELETE FROM t deletes no row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write),
    'r1,r2,r3',
    'neither permission: the owner finds every row there and unchanged');
ROLLBACK TO sp_n3;

-- Control: with the view permission as well, the same statements reach every row.
SAVEPOINT sp_n4;
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
INSERT INTO user_permissions (user_id, permission_name, granted_by)
SELECT u1.id, 'nrw:view', u3.id
  FROM users u1, users u3
 WHERE u1.external_id = 'user1' AND u3.external_id = 'user3';
SELECT authenticate_as('user1');
SELECT is(
    (SELECT count(*)::int FROM test_norule_write),
    3,
    'edit and view: user1 reads every row');
SELECT is(pg_temp.rows_written($$ UPDATE test_norule_write SET label = 'x' $$), '3',
    'edit and view: UPDATE t SET label = ''x'' writes every row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(label, ',' ORDER BY label) FROM test_norule_write),
    'x,x,x',
    'edit and view: the owner finds every row updated');
SELECT authenticate_as('user1');
SELECT is(pg_temp.rows_written($$ DELETE FROM test_norule_write $$), '3',
    'edit and view: DELETE FROM t deletes every row');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT count(*)::int FROM test_norule_write),
    0,
    'edit and view: the owner finds no row left');
ROLLBACK TO sp_n4;

-- The other paths that build these policies: an entity switched to managed,
-- the core tables generated at install, and a view_permission change. When
-- the two permissions are the same, the check is made once.
SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      view_permission, edit_permission, module_id, managed)
VALUES ('test_norule_toggle', 'test_norule_toggle_item', 'No-Rule Toggle Item', 'No-Rule Toggle Items',
        'Verifies the write policies of an entity without a select_rule that is switched to managed',
        'nrw:view', 'nrw:edit', 1, FALSE);
UPDATE entities SET managed = TRUE WHERE table_name = 'test_norule_toggle';
SELECT is(
    (SELECT string_agg(policyname || ': ' || qual, '; ' ORDER BY policyname) FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_toggle' AND cmd IN ('UPDATE', 'DELETE')),
    'test_norule_toggle_delete_policy: (( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''nrw:view''::text) AS has_permission)); '
    'test_norule_toggle_update_policy: (( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''nrw:view''::text) AS has_permission))',
    'switched to managed: UPDATE and DELETE check the edit permission and the view permission');

SELECT is(
    (SELECT string_agg(tablename || '.' || cmd || ': ' || qual, '; ' ORDER BY tablename, cmd) FROM pg_policies
      WHERE schemaname = 'public' AND tablename IN ('entities', 'fields') AND cmd IN ('UPDATE', 'DELETE')),
    'entities.DELETE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND (((( SELECT jl_request_context() AS jl_request_context) IS NOT NULL) AND ( SELECT rbac.has_permission(''admin''::text) AS has_permission)) OR select_rule_entities(entities.*, ( SELECT jl_request_context() AS jl_request_context)))); '
    'entities.UPDATE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND (((( SELECT jl_request_context() AS jl_request_context) IS NOT NULL) AND ( SELECT rbac.has_permission(''admin''::text) AS has_permission)) OR select_rule_entities(entities.*, ( SELECT jl_request_context() AS jl_request_context)))); '
    'fields.DELETE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND (table_name IN ( SELECT p.table_name' || E'\n' || '   FROM entities p))); '
    'fields.UPDATE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND (table_name IN ( SELECT p.table_name' || E'\n' || '   FROM entities p)))',
    'core tables: UPDATE and DELETE of entities check admin and the entities select_rule, whose leading admin term is checked once per statement, those of fields admin and the entities row a field belongs to');
SELECT is(
    (SELECT string_agg(cmd || ': ' || qual, '; ' ORDER BY cmd) FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'roles' AND cmd IN ('UPDATE', 'DELETE')),
    'DELETE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND ( SELECT rbac.has_permission(''public:read''::text) AS has_permission)); '
    'UPDATE: (( SELECT rbac.has_permission(''admin''::text) AS has_permission) AND ( SELECT rbac.has_permission(''public:read''::text) AS has_permission))',
    'core tables: roles, seen with public:read and edited with admin, checks both');

UPDATE entities SET view_permission = 'nrw:edit' WHERE table_name = 'test_norule_write';
SELECT is(
    (SELECT string_agg(cmd || ': ' || qual, '; ' ORDER BY cmd) FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write' AND cmd IN ('UPDATE', 'DELETE')),
    'DELETE: ( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission); '
    'UPDATE: ( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission)',
    'view_permission changed to the edit permission: UPDATE and DELETE are rebuilt with one check');
UPDATE entities SET view_permission = 'public:read' WHERE table_name = 'test_norule_write';
SELECT is(
    (SELECT string_agg(cmd || ': ' || qual, '; ' ORDER BY cmd) FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_write' AND cmd IN ('UPDATE', 'DELETE')),
    'DELETE: (( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''public:read''::text) AS has_permission)); '
    'UPDATE: (( SELECT rbac.has_permission(''nrw:edit''::text) AS has_permission) AND ( SELECT rbac.has_permission(''public:read''::text) AS has_permission))',
    'view_permission changed again: UPDATE and DELETE follow it');

-- =====================================================
-- AN ENTITY WITHOUT A RULE: EVERY PATH THAT REBUILDS UPDATE AND DELETE
-- =====================================================
-- build_select_rule_policy is the one generator of the UPDATE and DELETE
-- policies, and each change that has to rebuild them reaches it through a
-- trigger of its own: update_entity_policies for edit_permission,
-- manage_select_rule_policy for view_permission, select_rule and the name, and
-- a permission rename through either, since ON UPDATE CASCADE rewrites the
-- entities row and fires its row triggers. A path that missed the generator
-- would leave a policy naming a permission that no longer exists, or the
-- edit permission alone. Each case asserts the whole text of both policies,
-- their names included, so a policy left behind under an old name fails too.
--
-- pg_temp.write_policies lists the UPDATE and DELETE policies of a relation as
-- "name: USING / WITH CHECK"; pg_temp.norule_policies spells what an entity
-- without a rule has there, in the form the literal assertions above pin.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.write_policies(p_rel TEXT) RETURNS TEXT AS $$
    SELECT string_agg(policyname || ': ' || qual || ' / ' || coalesce(with_check, '-'), '; ' ORDER BY policyname)
      FROM pg_policies
     WHERE schemaname = 'public' AND tablename = p_rel AND cmd IN ('UPDATE', 'DELETE');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pg_temp.norule_policies(p_rel TEXT, p_edit TEXT, p_view TEXT) RETURNS TEXT AS $$
    SELECT format('%1$s_delete_policy: %2$s / -; %1$s_update_policy: %2$s / %3$s',
                  p_rel,
                  CASE WHEN p_edit = p_view THEN x.e ELSE format('(%s AND %s)', x.e, x.v) END,
                  x.e)
      FROM (SELECT format('( SELECT rbac.has_permission(%L::text) AS has_permission)', p_edit) AS e,
                   format('( SELECT rbac.has_permission(%L::text) AS has_permission)', p_view) AS v) x;
$$ LANGUAGE sql IMMUTABLE;

SELECT is(
    pg_temp.write_policies('test_norule_write'),
    pg_temp.norule_policies('test_norule_write', 'nrw:edit', 'public:read'),
    'paths, helper: norule_policies spells the text the literal assertion above pins');

SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      view_permission, edit_permission, module_id)
VALUES ('test_norule_paths', 'test_norule_paths_item', 'No-Rule Paths Item', 'No-Rule Paths Items',
        'Verifies that every change that rebuilds the write policies of an entity without a select_rule keeps the view permission',
        'nrw:view', 'nrw:edit', 1);

-- A permission rename, one side at a time: the cascade into edit_permission
-- reaches update_entity_policies, the one into view_permission
-- manage_select_rule_policy.
UPDATE permissions SET permission_name = 'nrw:editor' WHERE permission_name = 'nrw:edit';
SELECT is(
    pg_temp.write_policies('test_norule_paths'),
    pg_temp.norule_policies('test_norule_paths', 'nrw:editor', 'nrw:view'),
    'paths, edit permission renamed: UPDATE and DELETE name the new edit permission and keep the view permission');
UPDATE permissions SET permission_name = 'nrw:viewer' WHERE permission_name = 'nrw:view';
SELECT is(
    pg_temp.write_policies('test_norule_paths'),
    pg_temp.norule_policies('test_norule_paths', 'nrw:editor', 'nrw:viewer'),
    'paths, view permission renamed: UPDATE and DELETE name the new view permission');

UPDATE entities SET edit_permission = 'nwind:manage' WHERE table_name = 'test_norule_paths';
SELECT is(
    pg_temp.write_policies('test_norule_paths'),
    pg_temp.norule_policies('test_norule_paths', 'nwind:manage', 'nrw:viewer'),
    'paths, edit_permission changed: UPDATE and DELETE check the new edit permission and still the view permission');

UPDATE entities SET table_name = 'test_norule_paths2' WHERE table_name = 'test_norule_paths';
SELECT is(
    pg_temp.write_policies('test_norule_paths2'),
    pg_temp.norule_policies('test_norule_paths2', 'nwind:manage', 'nrw:viewer'),
    'paths, entity renamed: UPDATE and DELETE carry the new name and both permissions, and nothing is left under the old name');

-- A rule replaces the view permission in both policies; taking it away again
-- has to bring the view permission back, not leave the edit permission alone.
UPDATE entities SET select_rule = '{"has_permission":"admin"}'::jsonb WHERE table_name = 'test_norule_paths2';
SELECT is(
    (SELECT count(*)::int FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'test_norule_paths2' AND cmd IN ('UPDATE', 'DELETE')
        AND qual LIKE '%select_rule_test_norule_paths2%' AND qual NOT LIKE '%nrw:viewer%'),
    2,
    'paths, select_rule added: UPDATE and DELETE check the rule instead of the view permission');
UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'test_norule_paths2';
SELECT is(
    pg_temp.write_policies('test_norule_paths2'),
    pg_temp.norule_policies('test_norule_paths2', 'nwind:manage', 'nrw:viewer'),
    'paths, select_rule removed again: UPDATE and DELETE check the edit permission and the view permission');

-- A typeid root, and an is_a and a has_a entity below it, whose policies are
-- on <entity>_ext and carry that relation's name.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      view_permission, edit_permission)
VALUES ('test_norule_root', 'No-Rule Root', 'No-Rule Roots', 1, 'typeid', 'nrwroot',
        'nrw:viewer', 'nrw:editor');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('test_norule_isa', 'No-Rule Is-A', 'No-Rule Is-As', 1, 'is_a', 'nrwisa', 'test_norule_root',
        'public:read', 'nwind:manage');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                      view_permission, edit_permission)
VALUES ('test_norule_hasa', 'No-Rule Has-A', 'No-Rule Has-As', 1, 'has_a', 'test_norule_root',
        'nrw:viewer', 'nrw:viewer');
SELECT is(
    pg_temp.write_policies('test_norule_root'),
    pg_temp.norule_policies('test_norule_root', 'nrw:editor', 'nrw:viewer'),
    'paths, typeid root: UPDATE and DELETE check the edit permission and the view permission');
SELECT is(
    pg_temp.write_policies('test_norule_isa_ext'),
    pg_temp.norule_policies('test_norule_isa_ext', 'nwind:manage', 'public:read'),
    'paths, is_a: the UPDATE and DELETE policies of <entity>_ext check its edit permission and its view permission');
SELECT is(
    pg_temp.write_policies('test_norule_hasa_ext'),
    pg_temp.norule_policies('test_norule_hasa_ext', 'nrw:viewer', 'nrw:viewer'),
    'paths, has_a: the UPDATE and DELETE policies of <entity>_ext check its one permission once');
UPDATE entities SET edit_permission = 'nrw:editor' WHERE table_name = 'test_norule_hasa';
SELECT is(
    pg_temp.write_policies('test_norule_hasa_ext'),
    pg_temp.norule_policies('test_norule_hasa_ext', 'nrw:editor', 'nrw:viewer'),
    'paths, has_a edit_permission changed: <entity>_ext checks the new edit permission and the view permission');

-- enable_dd_table builds SELECT, UPDATE and DELETE itself rather than leaving
-- them to manage_select_rule_policy_trigger, which also fires on the managed
-- flip and, sorting after enable_table_trigger, would cover a missing call.
-- With that trigger off for the flip, the policies can come from
-- enable_dd_table alone.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
                      view_permission, edit_permission, module_id, managed)
VALUES ('test_norule_adopt', 'test_norule_adopt_item', 'No-Rule Adopt Item', 'No-Rule Adopt Items',
        'Verifies that enable_dd_table builds the write policies of an entity without a select_rule on its own',
        'nrw:viewer', 'nrw:editor', 1, FALSE);
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE entities DISABLE TRIGGER manage_select_rule_policy_trigger;
SELECT authenticate_as('user3');
UPDATE entities SET managed = TRUE WHERE table_name = 'test_norule_adopt';
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
ALTER TABLE entities ENABLE TRIGGER manage_select_rule_policy_trigger;
SELECT is(
    pg_temp.write_policies('test_norule_adopt'),
    pg_temp.norule_policies('test_norule_adopt', 'nrw:editor', 'nrw:viewer'),
    'paths, switched to managed with manage_select_rule_policy_trigger off: enable_dd_table builds UPDATE and DELETE itself');

SELECT * FROM finish();
ROLLBACK;
