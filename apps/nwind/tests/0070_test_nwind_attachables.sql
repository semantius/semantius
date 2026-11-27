-- =====================================================
-- NORTHWIND ATTACHMENTS TESTS (0070)
-- =====================================================
-- Tasks, files and comments (_core 0460_tasks_files_comments.jsonc) on the
-- orders and customers that 0010_nwind.jsonc switches them on for: who sees
-- them, their target labels, what a delete of an order does to them, and what
-- a delete of the module does; and the sample tasks
-- 0030_nwind_platform.once.sql seeds on six orders.
-- Writes are made as user2 (Northwind Sales); user1 holds no nwind permission.
-- The seeded orders are referenced by RESTRICT foreign keys, so the delete is
-- of an order created here. Everything is rolled back.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================
BEGIN;

SELECT plan(17);

-- The sample tasks, found where the seed puts them: in the Northwind Sales
-- queue, linked to one of the six orders. Never by their keys, which depend on
-- the tasks created before the module was installed. Read here, as the
-- installer, before the module delete at the end takes the links away.
CREATE TEMP TABLE nw_sample_tasks AS
SELECT t.id, o.label AS order_number
  FROM tasks t
  JOIN tasks_links l ON l.tasks_id = t.id
  JOIN orders o ON l.attached_to = 'orders:' || o.id
 WHERE t.assigned_role = (SELECT r.id FROM roles r WHERE r.slug = 'northwind_sales')
   AND o.label IN ('SO-10248', 'SO-10249', 'SO-10250', 'SO-11075', 'SO-11076', 'SO-11077');
GRANT SELECT ON nw_sample_tasks TO semantius_user;

SELECT is(
    (SELECT count(*)::int FROM entity_attachables
      WHERE target IN ('orders', 'customers') AND attachable IN ('tasks', 'files', 'comments')),
    6,
    'tasks, files and comments are switched on for orders and customers');

SELECT is(
    (SELECT string_agg(o.label || ' ' || s.n, ', ' ORDER BY o.id)
       FROM (SELECT split_part(l.attached_to, ':', 2)::bigint AS order_id, count(*) AS n
               FROM tasks_links l
               JOIN tasks t ON t.id = l.tasks_id
              WHERE t.status = 'open'
                AND t.assigned_role = (SELECT r.id FROM roles r WHERE r.slug = 'northwind_sales')
                AND t.assigned_user IS NULL
              GROUP BY 1) s
       JOIN orders o ON o.id = s.order_id),
    'SO-10248 2, SO-10249 2, SO-10250 2, SO-11075 2, SO-11076 2, SO-11077 2',
    'the three oldest and the three newest orders carry two open sample tasks each, waiting in the Northwind Sales queue');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM my_tasks() m WHERE m.id IN (SELECT s.id FROM nw_sample_tasks s)), 12,
    'a member of Northwind Sales finds the sample tasks in its inbox');

INSERT INTO comments (body, attached_to) VALUES ('Ship it on Monday', 'orders:10248');
SELECT is((SELECT attached_to_label(c) FROM comments c WHERE body = 'Ship it on Monday'),
    'Vins et alcools Chevalier › SO-10248',
    'a comment on an order shows the order''s composed label');

INSERT INTO files (name, content, attached_to)
SELECT 'contract.pdf', '\x255044462d'::bytea, 'customers:' || id FROM customers WHERE customer_id = 'ALFKI';
SELECT is((SELECT size FROM files WHERE name = 'contract.pdf'), 5::bigint,
    'a file is attached to a customer, which Northwind Sales may edit');

INSERT INTO tasks (title, assigned_user) VALUES ('Call back about 10248', 1002);
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT t.id, r.ref FROM tasks t,
       (VALUES ('orders:10248'), ((SELECT 'customers:' || id FROM customers WHERE customer_id = 'VINET'))) AS r(ref)
 WHERE t.title = 'Call back about 10248';
SELECT is((SELECT count(*)::int FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'Call back about 10248'), 2,
    'a task is linked to an order and to its customer');

-- The sample tasks took their numbers from the counter. Other tests take
-- numbers too, and a rolled-back insert keeps the number it took, so only the
-- floor is fixed.
SELECT ok((SELECT id::text ~ '^TASK-[1-9][0-9]*$'
                  AND substr(id::text, 6)::bigint > (SELECT max(substr(s.id::text, 6)::bigint) FROM nw_sample_tasks s)
             FROM tasks WHERE title = 'Call back about 10248'),
    'a new task takes the next number of the counter, above the numbers of the sample tasks');

SELECT authenticate_as('user1');
SELECT is((SELECT count(*)::int FROM comments WHERE body = 'Ship it on Monday')
          + (SELECT count(*)::int FROM files WHERE name = 'contract.pdf'), 0,
    'who cannot see the order or the customer sees neither its comments nor its files');

SELECT throws_ok(
    $$INSERT INTO comments (body, attached_to) VALUES ('Me too', 'orders:10248')$$,
    '91018', NULL,
    'and cannot comment on it');

-- A delete reaches what is attached to the order.
SELECT authenticate_as('user2');
INSERT INTO orders (ship_name, customer_id)
VALUES ('Attachments Order', (SELECT id FROM customers WHERE customer_id = 'ALFKI'));
INSERT INTO comments (body, attached_to)
SELECT 'Gone with the order', 'orders:' || id FROM orders WHERE ship_name = 'Attachments Order';
INSERT INTO files (name, content, attached_to)
SELECT 'packing-list.txt', '\x6869'::bytea, 'orders:' || id FROM orders WHERE ship_name = 'Attachments Order';
INSERT INTO tasks (title) VALUES ('Only about this order');
INSERT INTO tasks_links (tasks_id, attached_to)
SELECT t.id, 'orders:' || o.id FROM tasks t, orders o
 WHERE t.title IN ('Only about this order', 'Call back about 10248') AND o.ship_name = 'Attachments Order';

DELETE FROM orders WHERE ship_name = 'Attachments Order';
SELECT is((SELECT count(*)::int FROM comments WHERE body = 'Gone with the order')
          + (SELECT count(*)::int FROM files WHERE name = 'packing-list.txt'), 0,
    'deleting an order deletes its comments and the files it owns');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE title = 'Only about this order')
          AND NOT EXISTS (SELECT 1 FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'Only about this order'),
    'a task that was about that order only stays, without targets');
SELECT is((SELECT count(*)::int FROM tasks_links l JOIN tasks t ON t.id = l.tasks_id WHERE t.title = 'Call back about 10248'), 2,
    'a task about other records keeps its other links');

-- A key that is no value of the key type is refused as a record that does not
-- exist, also to a caller who sees the entity.
SELECT throws_ok(
    $$INSERT INTO comments (body, attached_to) VALUES ('Bad key', 'orders:abc')$$,
    '91018', NULL,
    'a malformed key is refused as no record, to a caller who sees the entity');
SELECT throws_ok(
    $$INSERT INTO comments (body, attached_to) VALUES ('Too big', 'orders:99999999999999999999')$$,
    '91018', NULL,
    'and so is a key beyond the range of its type');
SELECT throws_ok(
    $$INSERT INTO tasks_links (tasks_id, attached_to)
      SELECT id, 'customers:not-a-number' FROM tasks WHERE title = 'Call back about 10248'$$,
    '91018', NULL,
    'and a link to one');

-- A module delete takes what is attached to the module's records along, as
-- deleting each record would: comments and owned files go, tasks lose their
-- links and stay. The installer runs it: a privileged direct session.
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
    PERFORM set_config('request.jwt.claim.roles', '', true);
END $$;
SELECT lives_ok($$DELETE FROM modules WHERE module_slug = 'nwind'$$,
    'the nwind module is deleted while its sample tasks exist');
SELECT ok((SELECT count(*) FROM tasks t JOIN nw_sample_tasks s ON s.id = t.id) = 12
          AND EXISTS (SELECT 1 FROM tasks WHERE title = 'Call back about 10248')
          AND NOT EXISTS (SELECT 1 FROM tasks_links WHERE attached_to LIKE 'orders:%' OR attached_to LIKE 'customers:%')
          AND NOT EXISTS (SELECT 1 FROM comments WHERE attached_to LIKE 'orders:%')
          AND NOT EXISTS (SELECT 1 FROM files WHERE attached_to LIKE 'customers:%'),
    'the comments and files on its records go with them; the tasks lose their links and stay, without targets');

SELECT * FROM finish();
ROLLBACK;
