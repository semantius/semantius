-- The attach step and the policies of attachable entities
-- (0450_attachables.sql, dd_attach_policy_terms in 0210_computed_validation.sql).
--   PART 1  the attach step: the refusal that tells nothing, the canonical spelling
--   PART 2  single: view and edit follow the target
--   PART 3  owned_shared: the attach permission edit, links and their rights
--   PART 4  multiple: own permissions, links need both ends and the record's edit rights
--   PART 5  the check runs once per statement; the policies follow the targets
--
-- atp_secret is seen and edited with nwind:view and nwind:manage (user2,
-- user3), atp_open is seen by everyone and edited with admin (user3). user1
-- holds neither nwind permission. atp_task is seen by everyone and edited with
-- nwind:manage.
-- Fixture entities use the 'atp' prefix; everything is rolled back.
BEGIN;

SELECT plan(36);

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('atp_secret', 'Secret', 'Secrets', 1, 'nwind:view', 'nwind:manage'),
       ('atp_open', 'Open', 'Opens', 1, 'public:read', 'admin'),
       ('atp_third', 'Third', 'Thirds', 1, 'public:read', 'admin');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      attach_mode, attach_permission, attach_on_target_delete)
VALUES ('atp_comment', 'Comment', 'Comments', 1, 'public:read', 'public:read', 'single', 'view', 'cascade'),
       ('atp_file', 'File', 'Files', 1, 'public:read', 'public:read', 'owned_shared', 'edit', 'cascade'),
       ('atp_task', 'Task', 'Tasks', 1, 'public:read', 'nwind:manage', 'multiple', 'view', '');
INSERT INTO entity_attachables (target, attachable)
SELECT t, a FROM unnest(ARRAY['atp_secret', 'atp_open']) t, unnest(ARRAY['atp_comment', 'atp_file', 'atp_task']) a;

INSERT INTO atp_secret (label) VALUES ('S1');
INSERT INTO atp_open (label) VALUES ('O1');
INSERT INTO atp_third (label) VALUES ('T1');
-- The references, kept where every test user can read them.
DO $$
BEGIN
    PERFORM set_config('atp.s1', (SELECT 'atp_secret:' || id FROM atp_secret), true);
    PERFORM set_config('atp.o1', (SELECT 'atp_open:' || id FROM atp_open), true);
    PERFORM set_config('atp.t1', (SELECT 'atp_third:' || id FROM atp_third), true);
END $$;

-- The lines of a statement's plan.
CREATE FUNCTION pg_temp.plan_lines(p_sql text) RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    l text;
BEGIN
    FOR l IN EXECUTE 'EXPLAIN (VERBOSE, COSTS OFF) ' || p_sql LOOP
        RETURN NEXT l;
    END LOOP;
END $$;

-- =====================================================
-- PART 1: the attach step
-- =====================================================
SELECT authenticate_as('user1');

SELECT throws_ok(
    format($$INSERT INTO atp_comment (label, attached_to) VALUES ('c', %L)$$, current_setting('atp.s1')),
    '91018', 'No record ${reference} to attach ${attachable} records to',
    'a target record the caller cannot see is refused');

SELECT throws_ok(
    $$INSERT INTO atp_comment (label, attached_to) VALUES ('c', 'atp_secret:999999999')$$,
    '91018', 'No record ${reference} to attach ${attachable} records to',
    'with the same refusal as one that does not exist, so it tells nothing');

SELECT throws_ok(
    $$INSERT INTO atp_comment (label, attached_to) VALUES ('c', 'garbage')$$,
    '91018', NULL,
    'text that is no reference is refused the same way');

SELECT throws_ok(
    $$INSERT INTO atp_comment (label, attached_to) VALUES ('c', 'users:1001')$$,
    '91019', NULL,
    'a target entity that has not switched the attachable entity on is refused');

SELECT authenticate_as('user2');
INSERT INTO atp_comment (label, attached_to)
VALUES ('c secret', 'atp_secret:0' || split_part(current_setting('atp.s1'), ':', 2));
SELECT is((SELECT attached_to FROM atp_comment WHERE label = 'c secret'), current_setting('atp.s1'),
    'the reference is stored in its canonical spelling');

-- =====================================================
-- PART 2: single
-- =====================================================
SELECT authenticate_as('user1');
INSERT INTO atp_comment (label, attached_to) VALUES ('c open', current_setting('atp.o1'));
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM atp_comment), 'c open',
    'view follows the target: user1 sees the comment on the record it sees, not the one on the hidden record');

SELECT is((SELECT attached_to_label(c) FROM atp_comment c WHERE label = 'c open'), 'O1',
    'attached_to_label is the composed label of the target');

SELECT is(attached_to_label(jsonb_populate_record(NULL::atp_comment, jsonb_build_object('attached_to', current_setting('atp.s1')))),
    NULL,
    'and a target the caller cannot see shows no label');

SELECT authenticate_as('user2');
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM atp_comment), 'c open, c secret',
    'whoever sees the targets sees their comments');

SELECT authenticate_as('user1');
UPDATE atp_comment SET label = 'c open edited' WHERE label = 'c open';
SELECT is((SELECT label FROM atp_comment), 'c open',
    'edit follows the target: user1 may not edit atp_open, so not its comments either');

SELECT authenticate_as('user3');
SELECT throws_ok(
    $$UPDATE atp_comment SET label = 'c open edited', attached_to = current_setting('atp.s1') WHERE label = 'c open'$$,
    '91025', 'The target ${reference} of a record of ${attachable} is not changed',
    'the target of a comment is not changed');
UPDATE atp_comment SET label = 'c open edited', attached_to = current_setting('atp.o1') WHERE label = 'c open';
SELECT is((SELECT label || ' ' || (attached_to = current_setting('atp.o1')) FROM atp_comment WHERE label LIKE 'c open%'),
    'c open edited true',
    'who may edit the target edits the comment, and an update that sends its target as it is passes');

-- =====================================================
-- PART 3: owned_shared
-- =====================================================
SELECT authenticate_as('user1');
SELECT throws_ok(
    format($$INSERT INTO atp_file (label, attached_to) VALUES ('f', %L)$$, current_setting('atp.o1')),
    '91020', NULL,
    'attach permission edit: attaching needs the edit permission of the target');

SELECT authenticate_as('user2');
INSERT INTO atp_file (label, attached_to) VALUES ('f secret', current_setting('atp.s1'));
SELECT throws_ok(
    format($$INSERT INTO atp_file_links (atp_file_id, attached_to) SELECT id, %L FROM atp_file$$, current_setting('atp.o1')),
    '91020', NULL,
    'a link to a further target needs the attach permission on it');

SELECT authenticate_as('user3');
INSERT INTO atp_file_links (atp_file_id, attached_to) SELECT id, current_setting('atp.o1') FROM atp_file;

SELECT authenticate_as('user1');
SELECT is((SELECT count(*)::int FROM atp_file) + (SELECT count(*)::int FROM atp_file_links), 0,
    'view follows the owner: user1 sees neither the file owned by a hidden record nor its link to a visible one');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM atp_file) || '/' || (SELECT count(*)::int FROM atp_file_links), '1/1',
    'who sees the owner sees the file, and the link whose both ends are visible');

-- Removing a link needs the attach permission on its target, as adding one.
DELETE FROM atp_file_links;
SELECT authenticate_as('user3');
SELECT is((SELECT count(*)::int FROM atp_file_links), 1,
    'who may not edit the link''s target does not remove the link');
DELETE FROM atp_file_links;
SELECT ok(NOT EXISTS (SELECT 1 FROM atp_file_links), 'who may edit both ends does');

-- A file owned by a record user2 may not edit, linked to one it may.
INSERT INTO atp_file (label, attached_to) VALUES ('f open', current_setting('atp.o1'));
SELECT authenticate_as('user2');
SELECT throws_ok(
    format($$INSERT INTO atp_file_links (atp_file_id, attached_to) SELECT id, %L FROM atp_file WHERE label = 'f open'$$,
           current_setting('atp.s1')),
    '91023', NULL,
    'linking an owned_shared record needs the edit permission of its owner as well');
SELECT authenticate_as('user3');
DELETE FROM atp_file WHERE label = 'f open';

-- =====================================================
-- PART 4: multiple
-- =====================================================
SELECT authenticate_as('user2');
INSERT INTO atp_task (label) VALUES ('t1');
SELECT ok(EXISTS (SELECT 1 FROM atp_task WHERE label = 't1'), 'a multiple record needs no target');

SELECT authenticate_as('user1');
SELECT throws_ok(
    format($$INSERT INTO atp_task_links (atp_task_id, attached_to) SELECT id, %L FROM atp_task$$, current_setting('atp.s1')),
    '91018', NULL,
    'a link to a record the caller cannot see is refused');
SELECT throws_ok(
    format($$INSERT INTO atp_task_links (atp_task_id, attached_to) SELECT id, %L FROM atp_task$$, current_setting('atp.o1')),
    '42501', NULL,
    'a link of a task the caller sees but may not edit is refused, though the target is in view');

SELECT authenticate_as('user2');
INSERT INTO atp_task_links (atp_task_id, attached_to)
SELECT t.id, r.ref FROM atp_task t, unnest(ARRAY[current_setting('atp.o1'), current_setting('atp.s1')]) AS r(ref);
SELECT is((SELECT count(*)::int FROM atp_task_links), 2, 'user2 links the task it may edit to the records it sees');

SELECT authenticate_as('user1');
SELECT is((SELECT string_agg(attached_to, ', ') FROM atp_task_links), current_setting('atp.o1'),
    'a link row is visible only to whoever sees both ends');
DELETE FROM atp_task_links;
SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM atp_task_links), 2,
    'and who may not edit the task removes none of its links');

SELECT authenticate_as('user1');
SELECT is((SELECT count(*)::int FROM atp_task), 1, 'a multiple record keeps its own permissions, whatever its targets');

-- =====================================================
-- PART 5: once per statement, and the rebuilds
-- =====================================================
SELECT ok(
    (WITH p AS (SELECT l, row_number() OVER () AS n
                  FROM pg_temp.plan_lines('UPDATE atp_comment SET label = label') AS l)
     SELECT count(*) > 0
            AND bool_and((SELECT q.l ~ 'InitPlan' FROM p q
                           WHERE q.n < x.n AND q.l ~ '(InitPlan|SubPlan)'
                           ORDER BY q.n DESC LIMIT 1))
       FROM p x
      WHERE x.l LIKE '%has_permission(''nwind:manage''%'),
    'the target''s edit permission in the policy is checked once per statement (an InitPlan)');

SELECT lives_ok(
    $q$DO $do$ BEGIN PERFORM set_config('request.jwt.claim.sub', '', true); PERFORM set_config('app.context_initialized', '', true);
        PERFORM pg_temp.plan_lines('SELECT * FROM atp_comment'); END $do$$q$,
    'a guarded read plans without claims: nothing in the policy is evaluated at plan time');

RESET ROLE;
SELECT authenticate_as('user3');
UPDATE entities SET edit_permission = 'public:read' WHERE table_name = 'atp_open';
SELECT authenticate_as('user1');
UPDATE atp_comment SET label = 'c open by user1' WHERE label = 'c open edited';
SELECT is((SELECT label FROM atp_comment), 'c open by user1',
    'a changed edit permission of the target rebuilds the policies: user1 may edit now');

SELECT authenticate_as('user3');
INSERT INTO entity_attachables (target, attachable) VALUES ('atp_third', 'atp_comment');
SELECT authenticate_as('user1');
INSERT INTO atp_comment (label, attached_to) VALUES ('c third', current_setting('atp.t1'));
SELECT ok(EXISTS (SELECT 1 FROM atp_comment WHERE label = 'c third'),
    'a target switched on is in the policies at once');

SELECT authenticate_as('user3');
UPDATE entities SET table_name = 'atp_thirds' WHERE table_name = 'atp_third';
SELECT authenticate_as('user1');
SELECT is((SELECT split_part(attached_to, ':', 1) FROM atp_comment WHERE label = 'c third'), 'atp_thirds',
    'after a rename of the target its comments are rewritten and still visible');

SELECT authenticate_as('user3');
UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'atp_thirds';
SELECT authenticate_as('user1');
SELECT ok(NOT EXISTS (SELECT 1 FROM atp_comment WHERE label = 'c third'),
    'the target''s own row-level security decides: hidden now, so is its comment');

SELECT authenticate_as('user3');
UPDATE entities SET select_rule = '{"==": [{"var": "label"}, "nobody"]}'::jsonb WHERE table_name = 'atp_open';
SELECT authenticate_as('user1');
SELECT ok(NOT EXISTS (SELECT 1 FROM atp_comment WHERE label = 'c open by user1'),
    'so does a select_rule given to the target later: its record is hidden, and so is its comment');

-- A subtype added under a listed target after records were attached: its
-- records are admitted and their comments seen, by the policy rebuilt then.
SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_type, type_prefix)
VALUES ('atp_asset', 'Asset', 'Assets', 1, 'public:read', 'admin', 'typeid', 'atpasset');
INSERT INTO entity_attachables (target, attachable) VALUES ('atp_asset', 'atp_comment');
INSERT INTO atp_asset (label) VALUES ('A1');
INSERT INTO atp_comment (label, attached_to) SELECT 'c asset', 'atp_asset:' || id FROM atp_asset;
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                      id_type, type_prefix, id_refentity)
VALUES ('atp_laptop', 'Laptop', 'Laptops', 1, 'public:read', 'admin', 'is_a', 'atplap', 'atp_asset');
INSERT INTO atp_laptop (label) VALUES ('L1');
SELECT authenticate_as('user1');
INSERT INTO atp_comment (label, attached_to) SELECT 'c laptop', 'atp_laptop:' || id FROM atp_laptop;
SELECT is((SELECT string_agg(label, ', ' ORDER BY label) FROM atp_comment WHERE label IN ('c asset', 'c laptop')),
    'c asset, c laptop',
    'an is_a subtype added under a listed target later is admitted and in the policies at once');

-- A target switched off, and one dropped, leave the policies and lose their
-- delete step.
SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('atp_fourth', 'Fourth', 'Fourths', 1, 'public:read', 'admin'),
       ('atp_fifth', 'Fifth', 'Fifths', 1, 'public:read', 'admin');
INSERT INTO entity_attachables (target, attachable) VALUES ('atp_fourth', 'atp_comment'), ('atp_fifth', 'atp_comment');
DELETE FROM entity_attachables WHERE target = 'atp_fourth' AND attachable = 'atp_comment';
SELECT ok((SELECT p.qual FROM pg_policies p WHERE p.tablename = 'atp_comment' AND p.cmd = 'SELECT') NOT LIKE '%atp_fourth%'
          AND (SELECT p.qual FROM pg_policies p WHERE p.tablename = 'atp_comment' AND p.cmd = 'SELECT') LIKE '%atp_fifth%'
          AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.atp_fourth'::regclass AND tgname = 'attached_del'),
    'a target switched off leaves the policies of the attachable entity, and its table the delete step');
DELETE FROM entities WHERE table_name = 'atp_fifth';
SELECT ok((SELECT p.qual FROM pg_policies p WHERE p.tablename = 'atp_comment' AND p.cmd = 'SELECT') NOT LIKE '%atp_fifth%'
          AND to_regprocedure('common.attached_atp_fifth(text[])') IS NULL,
    'a target entity dropped leaves the policies, and its delete step goes');

SELECT * FROM finish();
ROLLBACK;
