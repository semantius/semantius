-- =====================================================
-- Values that reach SQL the dictionary builds (0537)
-- =====================================================
-- Every statement that builds SQL at run time was read, value by value, for
-- how the value gets into the text (docs/dynamic-sql-audit.md). This file
-- sends hostile values down the paths that reading could not close by itself:
--
--   PART 1  values that are safe only because a CHECK, an allow-list or a
--           lookup stands in front of the statement, and values that are
--           quoted but had no test: permission names, id_prefix, the code of
--           a validation rule, the name of a computed field, reference_table,
--           queue names, the names and literals of a rollup definition,
--           module and role names, and the one pgmq function that
--           concatenates its argument. Each as an administrator and as a
--           plain user, and afterward nothing a value names exists.
--   PART 2  names the dictionary generates or matches by pattern, where a
--           correctly quoted name still reaches another object
--   PART 3  a temporary table under the name of a dictionary table
--
-- 0535_test_identifier_hardening.sql covers the identifier columns and the
-- metadata text, 0530_test_default_value_hardening.sql the defaults and the
-- rule text. user3 is an administrator, user1 holds no permission that lets it
-- write the dictionary. Everything is rolled back.
BEGIN;

SELECT plan(103);

-- =====================================================
-- Helpers
-- =====================================================
-- pg_temp functions run as whichever user the test authenticated as.

-- What a statement is refused with: its SQLSTATE, followed by the CHECK
-- constraint its message names when it names one. 'accepted' when it is not
-- refused; what an accepted statement wrote stays.
CREATE FUNCTION pg_temp.s1_outcome(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_state   TEXT;
    v_message TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        RETURN 'accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    END;
    RETURN v_state || coalesce(' ' || substring(v_message FROM 'check constraint "([^"]+)"'), '');
END $f$;

-- Runs a statement and tells nothing: for a statement that only has to have
-- run, such as a write that fires a generated trigger.
CREATE FUNCTION pg_temp.s1_try(p_sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
EXCEPTION WHEN OTHERS THEN
    NULL;
END $f$;

-- The one value a query returns, as text, or the error it raises.
CREATE FUNCTION pg_temp.s1_value(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_value TEXT;
BEGIN
    EXECUTE p_sql INTO v_value;
    RETURN coalesce(v_value, 'NULL');
EXCEPTION WHEN OTHERS THEN
    RETURN format('ERROR %s: %s', SQLSTATE, SQLERRM);
END $f$;

-- What every hostile value below tries to do, and what must still be there.
CREATE TABLE public.s1_canary (id INT PRIMARY KEY);
INSERT INTO public.s1_canary VALUES (1);

-- Three ways out of a quoted context, each followed by the same statements.
CREATE TEMP TABLE s1_payloads (n INT PRIMARY KEY, kind TEXT NOT NULL, val TEXT NOT NULL);
GRANT SELECT ON s1_payloads TO semantius_user;
INSERT INTO s1_payloads VALUES
    (1, 'a single quote', 'x''); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --'),
    (2, 'a double quote', 'x"); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --'),
    (3, 'a dollar tag',   'x$s1$); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --');

-- The statement that puts p_value into the place p_case names. p_tag keeps
-- the names of two runs of one case apart.
CREATE FUNCTION pg_temp.s1_sql(p_case TEXT, p_tag TEXT, p_value TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT CASE p_case
        WHEN 'perm' THEN format(
            $q$INSERT INTO permissions (permission_name, description, module_id) VALUES (%L, 'hostile', 1)$q$, p_value)
        WHEN 'prefix' THEN format(
            $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_column,
                                     view_permission, edit_permission)
               VALUES (%L, 'Hostile', 'Hostiles', 1, 'typeid', %L, 'id', 'public:read', 'admin')$q$,
            's1_prefix_' || p_tag, p_value)
        WHEN 'vcode' THEN format(
            $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                                     validation_rules)
               VALUES (%L, 'Hostile', 'Hostiles', 1, 'public:read', 'admin', %L::jsonb)$q$,
            's1_vcode_' || p_tag,
            jsonb_build_array(jsonb_build_object('code', p_value, 'message', 'm',
                                                 'jsonlogic', '{"==": [1, 1]}'::jsonb))::text)
        WHEN 'cname' THEN format(
            $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                                     computed_fields)
               VALUES (%L, 'Hostile', 'Hostiles', 1, 'public:read', 'admin', %L::jsonb)$q$,
            's1_cname_' || p_tag,
            jsonb_build_array(jsonb_build_object('name', p_value, 'jsonlogic', '{"cat": ["a", "b"]}'::jsonb))::text)
        WHEN 'reft' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, reference_table)
               VALUES ('s1_host', %L, 'Hostile', 'reference', %L)$q$, 'ref_' || p_tag, p_value)
        WHEN 'queue' THEN format($q$INSERT INTO queues (queue_name) VALUES (%L)$q$, p_value)
        WHEN 'rlink' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rlink_' || p_tag,
            jsonb_build_object('link_field', p_value, 'function', 'count')::text)
        WHEN 'rfunc' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rfunc_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', p_value)::text)
        WHEN 'rvalue' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'number', %L::jsonb)$q$, 'rvalue_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', 'sum', 'value_field', p_value)::text)
        WHEN 'rvar' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rvar_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', 'count',
                               'filter', jsonb_build_object('==', jsonb_build_array(
                                             jsonb_build_object('var', p_value), 1)))::text)
        WHEN 'rlit' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rlit_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', 'count',
                               'filter', jsonb_build_object('==', jsonb_build_array(
                                             '{"var": "label"}'::jsonb, p_value)))::text)
        WHEN 'mname' THEN format(
            $q$INSERT INTO modules (module_name, module_slug, description) VALUES (%L, %L, 'hostile')$q$,
            p_value, 's1_mname_' || p_tag)
        WHEN 'mslug' THEN format(
            $q$INSERT INTO modules (module_name, module_slug, description) VALUES (%L, %L, 'hostile')$q$,
            'S1 Slug ' || p_tag, p_value)
        WHEN 'rname' THEN format($q$INSERT INTO roles (role_name, description) VALUES (%L, 'hostile')$q$,
            p_tag || ' ' || p_value)
        WHEN 'pgmq' THEN format($q$SELECT pgmq.convert_archive_partitioned(%L)$q$, p_value)
    END;
$f$;

-- What each case answers. An administrator is refused by the CHECK, the
-- allow-list or the lookup that stands in front of the statement, or the value
-- is stored as the text it is. A plain user is refused before that, by the
-- policies of the dictionary.
CREATE TEMP TABLE s1_cases (ord INT PRIMARY KEY, code TEXT NOT NULL, place TEXT NOT NULL,
                            as_admin TEXT NOT NULL, as_user TEXT NOT NULL);
GRANT SELECT ON s1_cases TO semantius_user;
INSERT INTO s1_cases VALUES
    (1,  'perm',   'permissions.permission_name',          '23514 permission_name_shape', '42501'),
    (2,  'prefix', 'entities.id_prefix',                   '23514 valid_id_prefix', '42501'),
    (3,  'vcode',  'the code of a validation rule',        '90905', '42501'),
    (4,  'cname',  'the name of a computed field',         'accepted', '42501'),
    (5,  'reft',   'fields.reference_table',               '90212', '90212'),
    (6,  'queue',  'queues.queue_name',                    'P0001', '42501'),
    (7,  'rlink',  'the link_field of a rollup',           '90262', '90262'),
    (8,  'rfunc',  'the function of a rollup',             '90263', '90263'),
    (9,  'rvalue', 'the value_field of a rollup',          '90264', '90264'),
    (10, 'rvar',   'a var in a rollup filter',             '90265', '42501'),
    (11, 'rlit',   'a literal in a rollup filter',         'accepted', '42501'),
    (12, 'mname',  'modules.module_name',                  'accepted', '42501'),
    (13, 'mslug',  'modules.module_slug',                  '90702', '90702'),
    (14, 'rname',  'roles.role_name',                      'accepted', '42501'),
    (15, 'pgmq',   'pgmq.convert_archive_partitioned',     'P0001', 'P0001');

-- =====================================================
-- PART 1: hostile values, as an administrator and as a plain user
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('s1_host',   'Host',   'Hosts',    1, 'public:read', 'admin'),
       ('s1_parent', 'Parent', 'Parents',  1, 'public:read', 'admin'),
       ('s1_child',  'Child',  'Children', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('s1_child', 'parent_id', 'Parent', 'parent', 10, 's1_parent', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('s1_child', 'amount', 'Amount', 'number', 20);
INSERT INTO s1_parent (label) VALUES ('p');

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'a' || p.n, p.val)), c.as_admin,
          format('%s, as an administrator: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_payloads ORDER BY n) p;

-- What was accepted is text now. Running what was generated from it must not
-- run it: a write to every entity built above, and a child under the parent
-- whose rollups hold the literals.
SELECT pg_temp.s1_try(format('INSERT INTO public.%I (label) VALUES (%L)', e.table_name, 'x'))
  FROM entities e
 WHERE e.table_name LIKE 's1\_cname\_%' OR e.table_name LIKE 's1\_vcode\_%' OR e.table_name LIKE 's1\_prefix\_%';
SELECT pg_temp.s1_try($$INSERT INTO s1_child (label, parent_id, amount) SELECT 'x', id, 1 FROM s1_parent$$);

SELECT authenticate_as('user1');

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'u' || p.n, p.val)), c.as_user,
          format('%s, as a plain user: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_payloads ORDER BY n) p;

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is((SELECT count(*)::int FROM pg_roles WHERE rolname = 's1_pwned'), 0,
    'no value created the role it names');
SELECT is(pg_temp.s1_value('SELECT count(*) FROM public.s1_canary'), '1',
    'no value dropped the table it names');
SELECT is(
    (SELECT count(*)::int FROM rbac.get_user_permissions_by_id(1001) WHERE permission_name = 'admin'),
    0,
    'and the plain user holds no admin afterward');

-- =====================================================
-- PART 2: generated and matched names
-- =====================================================
-- Quoting keeps a name from being read as SQL. It does not keep two names
-- from being one, or a pattern from matching a name it was not written for.
SELECT authenticate_as('user3');

-- The functions that label a record are found by their name ending in _label.
-- The one-argument rule predicate of an entity whose own name ends in _label
-- is select_rule_<entity>, and must not be taken for one of them.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, select_rule)
VALUES ('s1_ship_label', 'Ship Label', 'Ship Labels', 1, 'public:read', 'admin', '{"==": [1, 1]}'::jsonb);
INSERT INTO s1_ship_label (label) VALUES ('kept');
SELECT set_config('test.s1_label_id', (SELECT id::text FROM s1_ship_label), true);

SELECT authenticate_as('user1');
SELECT is(
    pg_temp.s1_value(format($q$SELECT get_record_by_id('s1_ship_label', %L) ->> 'label'$q$,
                            current_setting('test.s1_label_id'))),
    'kept',
    'an entity whose name ends in _label keeps its rule predicate: a plain user reads a record of it by id');

-- A rollup's maintenance function is named rollup_<child>_<link field>, and
-- the function that keeps the rollup columns of a parent from being written
-- by hand rollup_guard_<parent>. A child entity named guard with a link field
-- x spells the guard of a parent named x. Either the second definition is
-- refused or both work: the count is kept, and the guard still restores a
-- rollup column written by hand. (Two links that spell one name through the
-- underscore that joins child and field cannot both exist: the index of the
-- link field carries the same two names and refuses the second.)
SELECT authenticate_as('user3');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('s1x',       'X',     'Xs',     1, 'public:read', 'admin'),
       ('s1x_child', 'Child', 'Childs', 1, 'public:read', 'admin'),
       ('s1_top',    'Top',   'Tops',   1, 'public:read', 'admin'),
       ('guard',     'Guard', 'Guards', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('s1x_child', 'parent_id', 'X',   'parent', 10, 's1x',    'restrict'),
       ('guard',     's1x',       'Top', 'parent', 10, 's1_top', 'restrict');
INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
VALUES ('s1x', 'cnt', 'Count', 'int64', 20, '{"link_field": "s1x_child.parent_id", "function": "count"}');
SELECT set_config('test.s1_second_rollup', pg_temp.s1_outcome(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, rollup)
      VALUES ('s1_top', 'cnt', 'Count', 'int64', 20, '{"link_field": "guard.s1x", "function": "count"}')$$), true);
INSERT INTO s1x (label) VALUES ('x');
INSERT INTO s1_top (label) VALUES ('t');
SELECT pg_temp.s1_try($$INSERT INTO s1x_child (label, parent_id) SELECT 'c', id FROM s1x$$);
SELECT pg_temp.s1_try($$INSERT INTO guard (label, s1x) SELECT 'g', id FROM s1_top$$);
SELECT pg_temp.s1_try($$UPDATE s1x SET cnt = 99$$);

SELECT ok(
    current_setting('test.s1_second_rollup') LIKE '90%'
    OR (pg_temp.s1_value($$SELECT cnt FROM s1x$$) = '1' AND pg_temp.s1_value($$SELECT cnt FROM s1_top$$) = '1'),
    'a rollup function and a rollup guard that spell one name: the second is refused, or both work');

-- order_column names a column the dictionary adds and, when the entity stops
-- naming it, drops. A column that was there before, a field of the entity, is
-- not the dictionary's to drop.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('s1_ord', 'Ord', 'Ords', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format) VALUES ('s1_ord', 'note', 'Note', 'text');
INSERT INTO s1_ord (label, note) VALUES ('kept', 'kept');
SELECT pg_temp.s1_try($$UPDATE entities SET order_column = 'note' WHERE table_name = 's1_ord'$$);
SELECT pg_temp.s1_try($$UPDATE entities SET order_column = '' WHERE table_name = 's1_ord'$$);

SELECT is(pg_temp.s1_value($$SELECT note FROM s1_ord$$), 'kept',
    'an order_column that names a field of the entity does not cost the field its column');

-- A gate is installed as a trigger on the table its row names. That table has
-- to be an entity: an internal table is not one.
INSERT INTO processes (module_id, process_key, name, description, ordering)
VALUES (1, 's1_process', 'S1 Process', 'probe', 10);
SELECT isnt(
    pg_temp.s1_outcome($$INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
                         SELECT id, '_settings', 'approval', 'approved', 'value', FALSE
                           FROM processes WHERE process_key = 's1_process'$$),
    'accepted',
    'a process gate on an internal table is refused');

-- A column name longer than 63 bytes is not the name PostgreSQL stores. The
-- key guard is handed the name as text and compares a key the row does not
-- have, so the name is refused before anything is built from it.
SELECT isnt(
    pg_temp.s1_outcome(format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, id_column)
           VALUES ('s1_long_id', 'Long', 'Longs', 1, 'public:read', 'admin', %L)$q$, 'k' || repeat('a', 63))),
    'accepted',
    'an id_column of 64 bytes is refused');
SELECT isnt(
    pg_temp.s1_outcome(format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, label_column)
           VALUES ('s1_long_label', 'Long', 'Longs', 1, 'public:read', 'admin', %L)$q$, 'l' || repeat('a', 63))),
    'accepted',
    'a label_column of 64 bytes is refused');
SELECT isnt(
    pg_temp.s1_outcome(format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission, order_column)
           VALUES ('s1_long_order', 'Long', 'Longs', 1, 'public:read', 'admin', %L)$q$, 'o' || repeat('a', 63))),
    'accepted',
    'an order_column of 64 bytes is refused');

-- pgmq names the tables of a queue after the queue, in lower case. Two queue
-- names that differ in case only would share their tables.
SELECT set_config('test.s1_queue_upper', pg_temp.s1_outcome($$INSERT INTO queues (queue_name) VALUES ('S1_Case_Q')$$), true);
SELECT set_config('test.s1_queue_lower', pg_temp.s1_outcome($$INSERT INTO queues (queue_name) VALUES ('s1_case_q')$$), true);
SELECT ok(
    NOT (current_setting('test.s1_queue_upper') = 'accepted' AND current_setting('test.s1_queue_lower') = 'accepted'),
    'two queue names that differ in case only are not both accepted');

-- =====================================================
-- PART 3: a temporary table under the name of a dictionary table
-- =====================================================
-- A session that runs SQL as the request role may create temporary tables,
-- and PostgreSQL looks a table name up in the session's temporary schema
-- before any other. A definer function that names `users` without a schema
-- would read the caller's table and take the caller for whoever it says.
-- DISCARD PLANS makes the functions resolve their names again, as they do in
-- a session that created the table before its first call. This part is the
-- last: the temporary table is in the way of everything that reads users.
SELECT authenticate_as('user1');
SELECT pg_temp.s1_try($$CREATE TEMP TABLE users (id BIGINT, external_id TEXT, is_disabled BOOLEAN)$$);
SELECT pg_temp.s1_try($$INSERT INTO pg_temp.users VALUES (1003, 'user1', FALSE)$$);
SELECT pg_temp.s1_try($$GRANT SELECT ON pg_temp.users TO PUBLIC$$);
DISCARD PLANS;
SELECT set_config('app.current_user_id', '', true);
SELECT set_config('app.current_external_id', '', true);
SELECT set_config('app.user_permissions', '', true);
SELECT set_config('app.context_initialized', '', true);

SELECT is(rbac.user_id()::text, '1001',
    'a temporary table named users does not change who the caller is');
SELECT is(rbac.has_permission('admin'), FALSE,
    'and does not make the caller an administrator');

SELECT pg_temp.s1_try($$DROP TABLE IF EXISTS pg_temp.users$$);
DISCARD PLANS;

SELECT * FROM finish();
ROLLBACK;
