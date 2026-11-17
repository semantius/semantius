-- CURRENT_USER and $user_id as the default of a reference or parent field to users
-- (dd_is_current_user_default and dd_column_default, 0160_dd_functions.sql). The
-- column default is rbac.user_id_or_null(), so a write that leaves the field out
-- stores the id of the signed-in user, the way CURRENT_DATE on a date field stores
-- today. get_schema returns the default as written. A default never changes the
-- records already stored. The token is refused where it cannot mean the user (90283).
--
-- Parts:
--   1. The helpers
--   2. No signed-in user, as a migration runs: the column defaults, inserts
--   3. Inserts by a signed-in user, and get_schema
--   4. A field added to a table that already has rows
--   5. Setting and removing the default of an existing field
--   6. Where the token is refused (90283)
--   7. An is_a and a has_a entity, written through their views
BEGIN;

SELECT plan(46);

-- The default expression of a column as PostgreSQL stores it, NULL when there is none.
CREATE FUNCTION pg_temp.cu_default(p_table TEXT, p_column TEXT) RETURNS TEXT LANGUAGE sql AS $$
    SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid)
      FROM pg_catalog.pg_attribute a
      LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attrelid = pg_catalog.to_regclass('public.' || p_table)
       AND a.attname = p_column
       AND NOT a.attisdropped;
$$;

-- The ids of the test users, readable after authenticate_as, which may not see users.
SELECT set_config('cu.user1', (SELECT id::text FROM users WHERE external_id = 'user1'), true);
SELECT set_config('cu.user2', (SELECT id::text FROM users WHERE external_id = 'user2'), true);
SELECT set_config('cu.user3', (SELECT id::text FROM users WHERE external_id = 'user3'), true);

-- =====================================================
-- PART 1: The helpers
-- =====================================================
SELECT is(rbac.user_id_or_null(), NULL, 'the file starts with no signed-in user, as a migration runs');

SELECT ok(dd_is_current_user_default('reference', 'users', 'CURRENT_USER'),
    'CURRENT_USER on a reference to users is the current-user default');
SELECT ok(dd_is_current_user_default('parent', 'users', ' $User_Id '),
    'so is $user_id on a parent to users, in any case and with spaces around it');
SELECT ok(NOT dd_is_current_user_default('reference', 'roles', 'CURRENT_USER'),
    'a reference to another entity is not');
SELECT ok(NOT dd_is_current_user_default('int64', '', 'CURRENT_USER'),
    'nor a field that is not a reference');
SELECT ok(NOT dd_is_current_user_default('reference', 'users', NULL),
    'nor a reference without a default');
SELECT is(dd_column_default('reference', 'current_user', 'default', NULL, 'BIGINT', 'users'), 'rbac.user_id_or_null()',
    'the column default of the current-user default is rbac.user_id_or_null()');
SELECT is(dd_column_default('text', 'CURRENT_USER', 'default', NULL, 'TEXT'), 'CURRENT_USER',
    'a text field keeps PostgreSQL''s CURRENT_USER');

-- =====================================================
-- PART 2: No signed-in user
-- =====================================================
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('cu_notes', 'CU Note', 'CU Notes', 1, 'public:read', 'user:read'),
       ('cu_tasks', 'CU Task', 'CU Tasks', 1, 'public:read', 'user:read');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value) VALUES
    ('cu_notes', 'owner_id',    'Owner',    'reference', 'default',  'users', 'clear',    'CURRENT_USER'),
    ('cu_notes', 'reviewer_id', 'Reviewer', 'reference', 'required', 'users', 'restrict', '$user_id'),
    ('cu_tasks', 'owner_id',    'Owner',    'parent',    'default',  'users', 'cascade',  'CURRENT_USER');

SELECT is(pg_temp.cu_default('cu_notes', 'owner_id'), 'rbac.user_id_or_null()',
    'a reference to users with CURRENT_USER gets the column default rbac.user_id_or_null()');
SELECT is(pg_temp.cu_default('cu_notes', 'reviewer_id'), 'rbac.user_id_or_null()',
    'so does one with $user_id');
SELECT is(pg_temp.cu_default('cu_tasks', 'owner_id'), 'rbac.user_id_or_null()',
    'and a parent to users');

INSERT INTO cu_notes (label, reviewer_id) VALUES ('n0', current_setting('cu.user3')::bigint);
SELECT is((SELECT owner_id FROM cu_notes WHERE label = 'n0'), NULL,
    'without a signed-in user, an omitted reference stays NULL');
SELECT throws_ok($$INSERT INTO cu_notes (label) VALUES ('n0b')$$, '90258', NULL,
    'an omitted required reference is refused');
SELECT throws_ok($$INSERT INTO cu_tasks (label) VALUES ('t0')$$, '23502', NULL,
    'and an omitted parent fails NOT NULL');

-- =====================================================
-- PART 3: Inserts by a signed-in user, and get_schema
-- =====================================================
SELECT authenticate_as('user1');

INSERT INTO cu_notes (label) VALUES ('n1');
INSERT INTO cu_notes (label, owner_id) VALUES ('n2', current_setting('cu.user2')::bigint);
INSERT INTO cu_notes (label, owner_id) VALUES ('n3', NULL);
INSERT INTO cu_tasks (label) VALUES ('t1');

SELECT is((SELECT owner_id FROM cu_notes WHERE label = 'n1'), current_setting('cu.user1')::bigint,
    'an omitted reference stores the id of the signed-in user');
SELECT is((SELECT reviewer_id FROM cu_notes WHERE label = 'n1'), current_setting('cu.user1')::bigint,
    'so does an omitted required reference with $user_id');
SELECT is((SELECT owner_id FROM cu_tasks WHERE label = 't1'), current_setting('cu.user1')::bigint,
    'and an omitted parent');
SELECT is((SELECT owner_id FROM cu_notes WHERE label = 'n2'), current_setting('cu.user2')::bigint,
    'a value the write sends is kept');
SELECT is((SELECT owner_id FROM cu_notes WHERE label = 'n3'), NULL,
    'an explicit NULL is kept: a column default fills only a column the write leaves out');
SELECT throws_ok($$INSERT INTO cu_notes (label, reviewer_id) VALUES ('n4', NULL)$$, '90258', NULL,
    'so an explicit NULL on a required reference is refused');

SELECT is((public.get_schema('cu_notes')::jsonb)->'properties'->'owner_id'->>'default', 'CURRENT_USER',
    'get_schema returns the default as written, as it does CURRENT_DATE');
SELECT is((public.get_schema('cu_notes')::jsonb)->'properties'->'reviewer_id'->>'default', '$user_id',
    'and $user_id as written');
SELECT is((public.get_schema('cu_notes')::jsonb)->'properties'->'owner_id'->>'type', 'integer',
    'the property keeps the type of the key it holds');
SELECT ok(NOT ((public.get_schema('cu_tasks')::jsonb)->'required' @> '["owner_id"]'::jsonb),
    'a parent with the default is not listed as required: the database fills it');
SELECT lives_ok($$SELECT public.get_user_cubes()$$,
    'get_user_cubes builds the schemas of these entities');

-- =====================================================
-- PART 4: A field added to a table that already has rows
-- =====================================================
-- A default never changes records that already exist: the current-user default is
-- set only once the column exists, so the rows stay empty, and a field that cannot
-- stay empty there is refused as one without a default is.
SELECT authenticate_as('user3');

INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
VALUES ('cu_notes', 'editor_id', 'Editor', 'reference', 'default', 'users', 'clear', 'CURRENT_USER');
SELECT is((SELECT count(*)::int FROM cu_notes WHERE editor_id IS NOT NULL), 0,
    'a field added with the default to a table with rows leaves those rows empty');

INSERT INTO cu_notes (label) VALUES ('n5');
SELECT is((SELECT editor_id FROM cu_notes WHERE label = 'n5'), current_setting('cu.user3')::bigint,
    'and a later insert gets the signed-in user');

SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
      VALUES ('cu_notes', 'approver_id', 'Approver', 'reference', 'required', 'users', 'restrict', 'CURRENT_USER')$$,
    '90259', NULL, 'a required one is refused there: the existing rows would have no value');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
      VALUES ('cu_notes', 'boss_id', 'Boss', 'parent', 'default', 'users', 'cascade', 'CURRENT_USER')$$,
    '90259', NULL, 'and so is a parent, whose column is NOT NULL');

-- =====================================================
-- PART 5: Setting and removing the default of an existing field
-- =====================================================
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode)
VALUES ('cu_notes', 'helper_id', 'Helper', 'reference', 'default', 'users', 'clear');
UPDATE fields SET default_value = 'CURRENT_USER' WHERE table_name = 'cu_notes' AND field_name = 'helper_id';
SELECT is((SELECT count(*)::int FROM cu_notes WHERE helper_id IS NOT NULL), 0,
    'setting the default on an existing field changes no row');

INSERT INTO cu_notes (label) VALUES ('n6');
SELECT is((SELECT helper_id FROM cu_notes WHERE label = 'n6'), current_setting('cu.user3')::bigint,
    'and a later insert gets the signed-in user');

UPDATE fields SET default_value = '' WHERE table_name = 'cu_notes' AND field_name = 'helper_id';
SELECT is((SELECT helper_id FROM cu_notes WHERE label = 'n6'), current_setting('cu.user3')::bigint,
    'removing the default changes no row either');

INSERT INTO cu_notes (label) VALUES ('n7');
SELECT is((SELECT helper_id FROM cu_notes WHERE label = 'n7'), NULL,
    'and a later insert leaves the field empty');

SELECT lives_ok($$UPDATE fields SET title = 'Owner of the note' WHERE table_name = 'cu_notes' AND field_name = 'owner_id'$$,
    'a field with the default stays editable');

-- =====================================================
-- PART 6: Where the token is refused (90283)
-- =====================================================
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
      VALUES ('cu_notes', 'task_id', 'Task', 'reference', 'default', 'cu_tasks', 'clear', 'CURRENT_USER')$$,
    '90283', NULL, 'CURRENT_USER on a reference to another entity is refused');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, default_value)
      VALUES ('cu_notes', 'who', 'Who', 'text', '$user_id')$$,
    '90283', NULL, '$user_id on a text field is refused');
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, default_value)
      VALUES ('cu_notes', 'num', 'Num', 'int64', 'CURRENT_USER')$$,
    '90283', NULL, 'CURRENT_USER on a number is refused');
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, default_value)
      VALUES ('cu_notes', 'role_name', 'Role', 'text', 'CURRENT_USER')$$,
    'CURRENT_USER on a text field is accepted: it stores PostgreSQL''s role name, as it always has');
SELECT throws_ok(
    $$UPDATE fields SET reference_table = 'cu_tasks' WHERE table_name = 'cu_notes' AND field_name = 'owner_id'$$,
    '90283', NULL, 'pointing a field with the default at another entity is refused');
SELECT throws_ok(
    $$UPDATE fields SET format = 'int64', reference_table = '' WHERE table_name = 'cu_notes' AND field_name = 'owner_id'$$,
    '90283', NULL, 'and so is turning it into a number');
SELECT is(
    catch_error_hint($$INSERT INTO fields (table_name, field_name, title, format, default_value)
                       VALUES ('cu_notes', 'who2', 'Who', 'text', '$user_id')$$),
    '{"table": "cu_notes", "field_name": "who2", "default_value": "$user_id"}'::jsonb,
    '90283 names the table, the field and the default in its hint');

-- =====================================================
-- PART 7: An is_a and a has_a entity
-- =====================================================
-- Their records are written through a view, which copies each column's default from
-- the physical column whenever the family is rebuilt. That happens in the
-- statement-level triggers on fields (handle_field_searchable_*), after the row
-- trigger has added the column and only then set the current-user default, so the
-- view has to end up with it. A has_a record that attaches to an existing base
-- record compares a base column it left out with the column default, evaluated
-- again: with the current-user default that is the attaching user's id, not the
-- one stored, and the stored one must win without 90246.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, view_permission, edit_permission)
VALUES ('cu_items', 'CU Item', 'CU Items', 1, 'typeid', 'cuitm', 'public:read', 'user:read');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
VALUES ('cu_items', 'owner_id', 'Owner', 'reference', 'default', 'users', 'clear', 'CURRENT_USER');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity, view_permission, edit_permission)
VALUES ('cu_special', 'CU Special', 'CU Specials', 1, 'is_a', 'cuspc', 'cu_items', 'public:read', 'user:read');
INSERT INTO fields (table_name, field_name, title, format, input_type, reference_table, reference_delete_mode, default_value)
VALUES ('cu_special', 'checker_id', 'Checker', 'reference', 'default', 'users', 'clear', 'CURRENT_USER');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity, view_permission, edit_permission)
VALUES ('cu_extra', 'CU Extra', 'CU Extras', 1, 'has_a', 'cu_items', 'public:read', 'user:read');
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('cu_extra', 'note', 'Note', 'text');

SELECT authenticate_as('user1');
INSERT INTO cu_special (label) VALUES ('s1');
INSERT INTO cu_items (label) VALUES ('i1');

SELECT is((SELECT owner_id FROM cu_special WHERE label = 's1'), current_setting('cu.user1')::bigint,
    'is_a: a field of the root left out of a write through the subtype''s view stores the signed-in user');
SELECT is((SELECT checker_id FROM cu_special WHERE label = 's1'), current_setting('cu.user1')::bigint,
    'is_a: and so does a field of the subtype''s own table, added after the view existed');

SELECT authenticate_as('user2');
SELECT lives_ok($$INSERT INTO cu_extra (id, note) SELECT id, 'x' FROM cu_items WHERE label = 'i1'$$,
    'has_a: another user attaches to a base record and leaves its current-user field out');
SELECT is((SELECT owner_id FROM cu_extra WHERE label = 'i1'), current_setting('cu.user1')::bigint,
    'has_a: the base record keeps the user it stored');

INSERT INTO cu_extra (label, note) VALUES ('e2', 'y');
SELECT is((SELECT owner_id FROM cu_items WHERE label = 'e2'), current_setting('cu.user2')::bigint,
    'has_a: a new record creates its base record with the signed-in user');

SELECT * FROM finish();
ROLLBACK;
