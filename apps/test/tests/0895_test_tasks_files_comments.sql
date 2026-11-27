-- Tasks, files and comments (0460_tasks_files_comments.jsonc,
-- 0470_tasks_files_comments.sql).
--   PART 1  the permissions they are written with
--   PART 2  tasks: who sees them, claiming, delegating, changing, deleting
--   PART 3  my_tasks(), the inbox
--   PART 4  files: the size, the uploader
--   PART 5  comments: the label, the author, editing with the target
--   PART 6  links and the delete of a target, held to the task's rules
--
-- user1 and user2 hold the User role; user3 is the administrator, who holds
-- tasks:view_all and tasks:manage_all as every permission.
-- Fixture entities use the 'tfc' prefix; everything is rolled back.
BEGIN;

SELECT plan(47);

SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('tfc_case', 'Case', 'Cases', 1, 'public:read', 'public:read');
INSERT INTO entity_attachables (target, attachable)
VALUES ('tfc_case', 'tasks'), ('tfc_case', 'files'), ('tfc_case', 'comments');
INSERT INTO tfc_case (label) VALUES ('Case one');
DO $$
BEGIN
    PERFORM set_config('tfc.case', (SELECT 'tfc_case:' || id FROM tfc_case), true);
    PERFORM set_config('tfc.user_role', (SELECT id::text FROM roles WHERE role_name = 'User'), true);
END $$;

-- =====================================================
-- PART 1: the permissions
-- =====================================================
SELECT authenticate_as('user1');
SELECT ok(rbac.has_permission('public:write'), 'the User role holds public:write, the edit permission of the three');
SELECT ok(EXISTS (SELECT 1 FROM roles WHERE role_name = 'User'), 'roles are seen with public:read, so a task can name its role');
SELECT is(
    (SELECT string_agg(table_name || ' ' || attach_mode, ', ' ORDER BY table_name) FROM entities
      WHERE table_name IN ('tasks', 'files', 'comments')),
    'comments single, files owned_shared, tasks multiple',
    'the three are attachable entities of their modes');

-- =====================================================
-- PART 2: tasks
-- =====================================================
INSERT INTO tasks (title) VALUES ('tfc mine');
SELECT is(
    (SELECT created_by || ' ' || status || ' ' || priority FROM tasks WHERE title = 'tfc mine'),
    '1001 open normal',
    'a task records its creator, and starts open with normal priority');
-- A task's key is a Typed Number without padding. Other tests and the nwind
-- sample take numbers too, and a rolled-back insert keeps the number it took,
-- so the number is compared with the counter, not with a constant.
SELECT is((SELECT id::text FROM tasks WHERE title = 'tfc mine'), 'TASK-' || currval('public.tasks_id_seq'),
    'a task''s key is TASK- and the next number of the counter');
SELECT throws_ok($$INSERT INTO tasks (id, title) VALUES ('TASK-0' || currval('public.tasks_id_seq') + 1000, 'tfc padded')$$,
    '90287', NULL,
    'a supplied task key with a leading zero is refused: at the current width a number has one spelling');
INSERT INTO tasks (title, assigned_user) VALUES ('tfc for user2', 1002);

SELECT authenticate_as('user2');
SELECT is((SELECT string_agg(title, ', ' ORDER BY title) FROM tasks WHERE title LIKE 'tfc %'), 'tfc for user2',
    'a task is seen by its assignee and not by others');

SELECT authenticate_as('user3');
INSERT INTO tasks (title, assigned_role) VALUES ('tfc queued', current_setting('tfc.user_role')::bigint);
SELECT is((SELECT count(*)::int FROM tasks WHERE title LIKE 'tfc %'), 3,
    'a holder of tasks:view_all sees every task');

SELECT authenticate_as('user1');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc queued'),
    'a task in a role''s queue is seen by the members of the role');

SELECT throws_ok(
    $$UPDATE tasks SET assigned_user = 1001, title = 'tfc grabbed' WHERE title = 'tfc queued'$$,
    '90279', NULL,
    'claiming changes nothing but the assignee');
UPDATE tasks SET assigned_user = 1001 WHERE title = 'tfc queued';
SELECT is((SELECT assigned_user FROM tasks WHERE title = 'tfc queued'), 1001::bigint,
    'a member of the role claims a task without an assignee');

SELECT authenticate_as('user2');
SELECT throws_ok(
    $$UPDATE tasks SET assigned_user = 1002 WHERE title = 'tfc queued'$$,
    '90279', NULL,
    'a claimed task cannot be claimed again');

SELECT authenticate_as('user1');
UPDATE tasks SET assigned_user = 1002 WHERE title = 'tfc queued';
SELECT authenticate_as('user2');
SELECT is((SELECT assigned_user FROM tasks WHERE title = 'tfc queued'), 1002::bigint,
    'the assignee delegates the task');

SELECT authenticate_as('user1');
SELECT throws_ok(
    $$UPDATE tasks SET title = 'tfc renamed' WHERE title = 'tfc queued'$$,
    '90279', NULL,
    'a member of the role who is neither its assignee nor its creator does not change it');

SELECT authenticate_as('user3');
INSERT INTO tasks (title, assigned_role) VALUES ('tfc by admin', current_setting('tfc.user_role')::bigint);
SELECT authenticate_as('user2');
SELECT throws_ok(
    $$DELETE FROM tasks WHERE title = 'tfc by admin'$$,
    '90279', NULL,
    'nor delete it');

SELECT authenticate_as('user1');
DELETE FROM tasks WHERE title = 'tfc for user2';
SELECT ok(NOT EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc for user2'), 'the creator deletes the task');

UPDATE tasks SET status = 'done' WHERE title = 'tfc mine';
SELECT ok((SELECT completed_at IS NOT NULL FROM tasks WHERE title = 'tfc mine'), 'completed_at is set when the task is done');
UPDATE tasks SET status = 'open' WHERE title = 'tfc mine';
SELECT ok((SELECT completed_at IS NULL FROM tasks WHERE title = 'tfc mine'), 'and cleared when it is no longer done');

SELECT authenticate_as('user3');
UPDATE tasks SET description = 'looked at' WHERE title = 'tfc mine';
SELECT is((SELECT created_by FROM tasks WHERE title = 'tfc mine'), 1001::bigint,
    'a holder of tasks:manage_all changes any task, and the creator is kept');

SELECT authenticate_as('user1');
INSERT INTO tasks_links (tasks_id, attached_to) SELECT id, current_setting('tfc.case') FROM tasks WHERE title = 'tfc mine';
SELECT is((SELECT l.attached_to FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'tfc mine'),
    current_setting('tfc.case'), 'a task is linked to a record it is about');

-- =====================================================
-- PART 3: my_tasks()
-- =====================================================
INSERT INTO tasks (title, assigned_user, due_at, priority) VALUES
    ('tfc mt later', 1001, '2026-12-02 09:00:00+00', 'normal'),
    ('tfc mt soon low', 1001, '2026-12-01 09:00:00+00', 'low'),
    ('tfc mt soon high', 1001, '2026-12-01 09:00:00+00', 'high');
INSERT INTO tasks (title, assigned_user, snoozed_until) VALUES
    ('tfc mt snoozed', 1001, '2999-01-01 00:00:00+00'),
    ('tfc mt woken', 1001, '2000-01-01 00:00:00+00');
INSERT INTO tasks (title, assigned_user, status) VALUES ('tfc mt done', 1001, 'done');
INSERT INTO tasks (title, assigned_role) VALUES ('tfc mt queue', current_setting('tfc.user_role')::bigint);

SELECT is(
    (SELECT string_agg(m.title, ', ' ORDER BY m.ordinality) FROM my_tasks() WITH ORDINALITY AS m WHERE m.title LIKE 'tfc mt %'),
    'tfc mt soon high, tfc mt soon low, tfc mt later, tfc mt woken, tfc mt queue',
    'my_tasks: open tasks of the caller and of its roles'' queues, not snoozed, by due date then priority');

SELECT ok(NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.my_tasks()'::regprocedure),
    'my_tasks runs as the caller, under the tasks'' own row-level security');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM my_tasks() WHERE title LIKE 'tfc mt %'), 1,
    'another user''s inbox holds only the queue task they share a role for');

-- =====================================================
-- PART 4: files
-- =====================================================
SELECT authenticate_as('user1');
INSERT INTO files (name, content_type, content, attached_to)
VALUES ('tfc a.bin', 'application/octet-stream', '\x010203'::bytea, current_setting('tfc.case'));
SELECT is((SELECT size || ' ' || created_by FROM files WHERE name = 'tfc a.bin'), '3 1001',
    'a file''s size is the length of its contents, and it records its uploader');
UPDATE files SET content = '\x0102030405'::bytea WHERE name = 'tfc a.bin';
SELECT is((SELECT size FROM files WHERE name = 'tfc a.bin'), 5::bigint, 'the size follows the contents');
SELECT throws_ok(
    $$INSERT INTO files (name, content) VALUES ('tfc orphan', '\x00'::bytea)$$,
    '90258', NULL,
    'a file needs an owner');

SELECT authenticate_as('user2');
UPDATE files SET size = 99 WHERE name = 'tfc a.bin';
SELECT is((SELECT size || ' ' || created_by FROM files WHERE name = 'tfc a.bin'), '5 1001',
    'nobody writes the size, and the uploader is kept');

-- =====================================================
-- PART 5: comments
-- =====================================================
SELECT authenticate_as('user1');
INSERT INTO comments (body, attached_to) VALUES (repeat('abcdefghij', 9), current_setting('tfc.case'));
SELECT is((SELECT label FROM comments WHERE created_by = 1001), repeat('abcdefghij', 8),
    'the label of a comment is the first 80 characters of its body');

SELECT throws_ok(
    $$INSERT INTO comments (body) VALUES ('no target')$$,
    '90258', NULL,
    'a comment needs a target');

SELECT authenticate_as('user2');
UPDATE comments SET body = 'edited by user2' WHERE created_by = 1001;
SELECT is((SELECT body || ' ' || created_by FROM comments WHERE created_by = 1001), 'edited by user2 1001',
    'who may edit the target edits its comments, and the author is kept');

SELECT authenticate_as('user3');
UPDATE entities SET edit_permission = 'admin' WHERE table_name = 'tfc_case';
SELECT authenticate_as('user2');
UPDATE comments SET body = 'again' WHERE created_by = 1001;
SELECT is((SELECT body FROM comments WHERE created_by = 1001), 'edited by user2',
    'who may not edit the target does not edit its comments');
SELECT is((SELECT count(*)::int FROM comments WHERE created_by = 1001), 1, 'but still sees them');

SELECT authenticate_as('user3');
SELECT is((get_schema('tfc_case')::jsonb) -> 'attachables', '["comments", "files", "tasks"]'::jsonb,
    'the target reports the three');

DELETE FROM tfc_case;
SELECT is(
    (SELECT count(*)::int FROM comments WHERE attached_to = current_setting('tfc.case'))
    + (SELECT count(*)::int FROM files WHERE attached_to = current_setting('tfc.case'))
    + (SELECT count(*)::int FROM tasks_links WHERE attached_to = current_setting('tfc.case')),
    0,
    'deleting the target deletes its comments and files and removes its task links');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc mine'),
    'and a task whose last target it was stays, without targets');

-- =====================================================
-- PART 6: links and the delete of a target
-- =====================================================
-- A link row is written on behalf of its task, so adding or removing one needs
-- the rights to change the task: its rule 90279 refuses whoever may see the
-- task but not change it while the target exists. The delete of a target
-- removes the links to it, as a foreign-key cascade would, so it neither needs
-- those rights nor tells of the tasks; a task that lost its last target stays,
-- without targets.
SELECT authenticate_as('user3');
UPDATE entities SET edit_permission = 'public:read' WHERE table_name = 'tfc_case';
INSERT INTO tfc_case (label) VALUES ('Case two'), ('Case three');
DO $$
BEGIN
    PERFORM set_config('tfc.case2', (SELECT 'tfc_case:' || id FROM tfc_case WHERE label = 'Case two'), true);
    PERFORM set_config('tfc.case3', (SELECT 'tfc_case:' || id FROM tfc_case WHERE label = 'Case three'), true);
END $$;
INSERT INTO tasks (title, assigned_role) VALUES ('tfc admin queued', current_setting('tfc.user_role')::bigint);
INSERT INTO tasks (title) VALUES ('tfc admin solo');
DO $$
BEGIN
    PERFORM set_config('tfc.solo', (SELECT id FROM tasks WHERE title = 'tfc admin solo'), true);
END $$;
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT id, current_setting('tfc.case2') FROM tasks WHERE title = 'tfc admin queued';

SELECT authenticate_as('user1');
SELECT throws_ok(
    $$INSERT INTO tasks_links (tasks_id, attached_to)
      SELECT id, current_setting('tfc.case3') FROM tasks WHERE title = 'tfc admin queued'$$,
    '90279', NULL,
    'a member of the task''s role, who sees it but may not change it, does not link it to a record');
SELECT throws_ok(
    $$DELETE FROM tasks_links WHERE attached_to = current_setting('tfc.case2')$$,
    '90279', NULL,
    'nor removes its link while the record it links to exists');
SELECT throws_ok(
    $$INSERT INTO tasks_links (tasks_id, attached_to) VALUES (current_setting('tfc.solo'), current_setting('tfc.case3'))$$,
    '91021', 'No record ${reference} to link to ${target}',
    'a task the caller does not see is not linked');

RESET ROLE;
INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, 'tasks:view_all' FROM users u WHERE u.external_id = 'user2';
SELECT authenticate_as('user2');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc admin solo'),
    'a holder of tasks:view_all sees a task of another user');
SELECT throws_ok(
    $$INSERT INTO tasks_links (tasks_id, attached_to)
      SELECT id, current_setting('tfc.case3') FROM tasks WHERE title = 'tfc admin solo'$$,
    '90279', NULL,
    'but does not link it to a record');

SELECT authenticate_as('user1');
SELECT lives_ok(
    $$DELETE FROM tfc_case WHERE label = 'Case two'$$,
    'who may delete a target deletes it, though it may not change a task linked to it');
RESET ROLE;
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc admin queued')
          AND NOT EXISTS (SELECT 1 FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'tfc admin queued'),
    'and the task that lost its last target stays, without targets');

-- A task of user1 on a record of user2, and one on that record and another.
SELECT authenticate_as('user2');
INSERT INTO tfc_case (label) VALUES ('Case of user2');
SELECT authenticate_as('user1');
INSERT INTO tasks (title) VALUES ('tfc u1 only there'), ('tfc u1 there and elsewhere');
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT t.id, 'tfc_case:' || c.id FROM tasks t, tfc_case c
 WHERE t.title IN ('tfc u1 only there', 'tfc u1 there and elsewhere') AND c.label = 'Case of user2'
UNION ALL
SELECT t.id, current_setting('tfc.case3') FROM tasks t WHERE t.title = 'tfc u1 there and elsewhere';
SELECT authenticate_as('user2');
SELECT lives_ok($$DELETE FROM tfc_case WHERE label = 'Case of user2'$$,
    'the owner of a record deletes it, whatever tasks of others are linked to it');
SELECT authenticate_as('user1');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc u1 only there')
          AND NOT EXISTS (SELECT 1 FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'tfc u1 only there')
          AND (SELECT string_agg(l.attached_to, ', ') FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id
                WHERE t.title = 'tfc u1 there and elsewhere') = current_setting('tfc.case3'),
    'the task linked only to it stays without targets; one with a target left keeps that link');

-- A privileged direct session - the installer, a seed, an import, a module
-- delete - has no user and passes the rule.
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
    PERFORM set_config('request.jwt.claim.roles', '', true);
END $$;
UPDATE tasks SET title = 'tfc admin solo, renamed by the installer' WHERE title = 'tfc admin solo';
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc admin solo, renamed by the installer'),
    'a privileged session changes a task it neither created nor is assigned');

-- An administrator without tasks:manage_all deletes a module through the API,
-- whose records carry tasks of others.
INSERT INTO roles (role_name, description) VALUES ('Tfc Admins', 'admin without tasks:manage_all');
INSERT INTO role_permissions (role_id, permission_name) SELECT id, 'admin' FROM roles WHERE role_name = 'Tfc Admins';
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id FROM users u, roles r WHERE u.external_id = 'user1' AND r.role_name = 'Tfc Admins';
INSERT INTO modules (module_name, module_slug, description, view_permission)
VALUES ('Tfc Module', 'tfcmod', 'tasks fixture', 'user:read');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('tfc_deal', 'Deal', 'Deals', (SELECT id FROM modules WHERE module_slug = 'tfcmod'), 'public:read', 'admin');
INSERT INTO entity_attachables (target, attachable) VALUES ('tfc_deal', 'tasks');
INSERT INTO tfc_deal (label) VALUES ('Deal one');
SELECT authenticate_as('user3');
INSERT INTO tasks (title) VALUES ('tfc about the deal');
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT t.id, 'tfc_deal:' || d.id FROM tasks t, tfc_deal d WHERE t.title = 'tfc about the deal';
SELECT authenticate_as('user1');
SELECT lives_ok($$DELETE FROM modules WHERE module_slug = 'tfcmod'$$,
    'an administrator without tasks:manage_all deletes a module whose records carry tasks of others');
RESET ROLE;
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'tfc about the deal')
          AND NOT EXISTS (SELECT 1 FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'tfc about the deal'),
    'and the task on its record stays, without targets');

SELECT * FROM finish();
ROLLBACK;
