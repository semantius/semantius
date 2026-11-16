-- =====================================================
-- Values that reach SQL the dictionary builds (0537)
-- =====================================================
-- Every statement that builds SQL at run time was read, value by value, for
-- how the value gets into the text (docs/dynamic-sql-audit.md). This file
-- sends hostile values down the paths that reading could not close by itself:
--
--   PART 1  values that are safe only because a CHECK, an allow-list, a
--           lookup or a foreign key stands in front of the statement, and
--           values that are quoted but had no test: permission names,
--           id_prefix, the code of a validation rule, the name of a computed
--           field, reference_table, queue names, the names, literals and
--           operators of a rollup definition, module and role names, the
--           table of a queue mapping, the entity of a process gate, table
--           names and key columns, the conditional of pgmq.read, and the one
--           pgmq function that concatenates its argument. Each as an
--           administrator and as a plain user, first with values that end
--           the statement they are spliced into, then with values that need
--           no semicolon, quote or dollar sign. What is accepted is stored as
--           written and what is generated from it works, and afterward
--           nothing a value names exists and nothing it calls has run. Last,
--           the paths no caller reaches, ensure_entities and pgmq's
--           partitioned queues, and what keeps the request role out of them.
--   PART 2  names the dictionary generates or matches by pattern, where a
--           correctly quoted name still reaches another object
--   PART 3  a temporary table under the name of a dictionary table
--
-- 0535_test_identifier_hardening.sql covers the identifier columns and the
-- metadata text, 0530_test_default_value_hardening.sql the defaults and the
-- rule text. user3 is an administrator, user1 holds no permission that lets it
-- write the dictionary. Everything is rolled back.
BEGIN;

SELECT plan(437);

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

-- A value without a semicolon cannot add a statement, only change the one it
-- is spliced into, so what such a value does is call public.s1_hit() from
-- inside an expression. The call advances a sequence, and a sequence keeps
-- its value when the statement that advanced it fails, so a call leaves its
-- trace even where the statement around it is refused afterward, as most of
-- the statements below are. Granted to PUBLIC, so the call would succeed as
-- the request role and as the owner of the definer functions alike.
CREATE SEQUENCE public.s1_hits;
GRANT USAGE ON SEQUENCE public.s1_hits TO PUBLIC;
CREATE FUNCTION public.s1_hit() RETURNS BIGINT LANGUAGE sql SET search_path = pg_catalog, pg_temp
AS $f$ SELECT nextval('public.s1_hits') $f$;
GRANT EXECUTE ON FUNCTION public.s1_hit() TO PUBLIC;

-- The one call the file makes itself, from a statement that fails.
SELECT pg_temp.s1_try('SELECT public.s1_hit() / 0');
SELECT is((SELECT last_value || ' ' || is_called FROM public.s1_hits), '1 true',
    'a call of s1_hit is counted even when the statement that made it is refused');

-- Three ways out of a quoted context, each followed by the same statements.
CREATE TEMP TABLE s1_payloads (n INT PRIMARY KEY, kind TEXT NOT NULL, val TEXT NOT NULL);
GRANT SELECT ON s1_payloads TO semantius_user;
INSERT INTO s1_payloads VALUES
    (1, 'a single quote', 'x''); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --'),
    (2, 'a double quote', 'x"); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --'),
    (3, 'a dollar tag',   'x$s1$); CREATE ROLE s1_pwned; DROP TABLE public.s1_canary; --');

-- Each of the three carries a semicolon, a comment marker and an upper case
-- letter, so a filter that looks for any of those (pgmq's check of a queue
-- name, the lower case rule of queue names) refuses it before it reaches the
-- statement behind the filter. These four carry none of them, nor a single
-- quote or a dollar sign, and stay within 41 bytes, the longest table name,
-- so they reach that statement. Each changes what a statement means if it is
-- spliced into it raw:
--   4  closes a quoted identifier, and between the two names calls the
--      canary: "x"||public.s1_hit()||"x" is an expression;
--   5  ends a block comment the value was put into and opens another one
--      after the call;
--   6  ends a line comment, so the call stands on a line of its own, and
--      passes a check that tests each line instead of the whole value;
--   7  a trailing backslash escapes the closing quote of an E'' literal,
--      %s and %% are placeholders in a value reused as a format() string,
--      % and _ are wildcards of a LIKE pattern, and the colon separates the
--      old and the new name in the rename marker dd.table_rename.
CREATE TEMP TABLE s1_quiet (n INT PRIMARY KEY, kind TEXT NOT NULL, val TEXT NOT NULL);
GRANT SELECT ON s1_quiet TO semantius_user;
INSERT INTO s1_quiet VALUES
    (4, 'a double quote and no semicolon', 'x"||public.s1_hit()||"x'),
    (5, 'a block comment',                 'x*/public.s1_hit()/*x'),
    (6, 'line breaks',                     E'x\npublic.s1_hit()\nx'),
    (7, 'a backslash, percent signs, an underscore and a colon', E'x\\%s%%_:\\');

-- A rename as the caller. A plain user's UPDATE of entities matches no row
-- the policies let it change, which is no error, so a rename that changed
-- nothing is reported as no_data_found (P0002) and cannot pass for accepted.
CREATE FUNCTION pg_temp.s1_rename(p_value TEXT) RETURNS VOID LANGUAGE plpgsql AS $f$
BEGIN
    UPDATE entities SET table_name = p_value WHERE table_name = 's1_ren';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no row of entities was renamed' USING ERRCODE = 'no_data_found';
    END IF;
END $f$;

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
        WHEN 'qtable' THEN format(
            $q$INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
               VALUES (current_setting('test.s1_queue')::bigint, 'hostile', %L, 'insert')$q$, p_value)
        WHEN 'gate' THEN format(
            $q$INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
               VALUES (current_setting('test.s1_process')::bigint, %L, 'approval', 'approved', 'status', TRUE)$q$,
            p_value)
        WHEN 'qread' THEN format(
            $q$SELECT count(*) FROM pgmq.read('s1_q', 0, 1, jsonb_build_object(%L, %L))$q$, p_value, p_value)
        WHEN 'rcmp' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rcmp_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', 'count',
                               'filter', jsonb_build_object(p_value, jsonb_build_array(
                                             '{"var": "label"}'::jsonb, 'x')))::text)
        WHEN 'rdop' THEN format(
            $q$INSERT INTO fields (table_name, field_name, title, format, rollup)
               VALUES ('s1_parent', %L, 'Hostile', 'int64', %L::jsonb)$q$, 'rdop_' || p_tag,
            jsonb_build_object('link_field', 's1_child.parent_id', 'function', 'count',
                               'filter', jsonb_build_object('==', jsonb_build_array(
                                             jsonb_build_object(p_value, '2020-01-01'), 1)))::text)
        WHEN 'tname' THEN format(
            $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
               VALUES (%L, 'Hostile', 'Hostiles', 1, 'public:read', 'admin')$q$, p_value)
        WHEN 'tren' THEN format($q$SELECT pg_temp.s1_rename(%L)$q$, p_value)
        WHEN 'idcol' THEN format(
            $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission,
                                     id_column)
               VALUES (%L, 'Hostile', 'Hostiles', 1, 'public:read', 'admin', %L)$q$, 's1_idcol_' || p_tag, p_value)
        WHEN 'ensure' THEN format(
            $q$SELECT public.ensure_entities(jsonb_build_object('version', 1, 'module',
                   jsonb_build_object('module_name', 's1_ensure', %L, 1)))$q$, p_value)
        -- Run as the installer only, below.
        WHEN 'erec' THEN format(
            $q$SELECT public.ensure_entities(jsonb_build_object('version', 1, 'entities', jsonb_build_array(
                   jsonb_build_object('entity', jsonb_build_object('table_name', 's1_host'),
                                      'records', jsonb_build_array(jsonb_build_object('id', 1, %L, 1))))))$q$, p_value)
    END;
$f$;

-- The text an accepted value is stored as, read from the row its case wrote.
-- A role name carries the tag of its run in front of the value.
CREATE FUNCTION pg_temp.s1_stored_sql(p_case TEXT, p_tag TEXT, p_value TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT CASE p_case
        WHEN 'cname' THEN format(
            $q$SELECT computed_fields -> 0 ->> 'name' FROM entities WHERE table_name = %L$q$, 's1_cname_' || p_tag)
        WHEN 'rlit' THEN format(
            $q$SELECT rollup -> 'filter' -> '==' ->> 1 FROM fields WHERE table_name = 's1_parent' AND field_name = %L$q$,
            'rlit_' || p_tag)
        WHEN 'mname' THEN format($q$SELECT module_name FROM modules WHERE module_slug = %L$q$, 's1_mname_' || p_tag)
        WHEN 'rname' THEN format(
            $q$SELECT substr(role_name, %s) FROM roles WHERE starts_with(role_name, %L)$q$,
            length(p_tag) + 2, p_tag || ' ')
        -- Found by the value itself: text equality under the database's
        -- deterministic collation is equality byte for byte.
        WHEN 'queue' THEN format($q$SELECT queue_name FROM queues WHERE queue_name = %L$q$, p_value)
        WHEN 'gate' THEN format(
            $q$SELECT entity FROM process_gates
                WHERE process_id = current_setting('test.s1_process')::bigint AND entity = %L$q$, p_value)
    END;
$f$;

-- What each case answers: as_admin and as_user for the three values that end
-- the statement, quiet_admin and quiet_user for the four without a semicolon.
-- An administrator is refused by the CHECK, the allow-list, the lookup or the
-- foreign key that stands in front of the statement, or the value is stored
-- as the text it is. A plain user is refused by the policies of the
-- dictionary, or before them by the same check where it runs in a BEFORE
-- trigger. The two sets differ where the filter is what refused the first
-- set: the quiet values pass the lower case rule of queue names and are
-- stored as queue names, and they fit the 41 bytes of a table name, so there
-- the CHECK refuses them, not the length. pgmq.read builds its statement with
-- the conditional for either user and is then refused the queue table, which
-- the request role has no privilege on.
CREATE TEMP TABLE s1_cases (ord INT PRIMARY KEY, code TEXT NOT NULL, place TEXT NOT NULL,
                            as_admin TEXT NOT NULL, as_user TEXT NOT NULL,
                            quiet_admin TEXT NOT NULL, quiet_user TEXT NOT NULL);
GRANT SELECT ON s1_cases TO semantius_user;
INSERT INTO s1_cases VALUES
    (1,  'perm',   'permissions.permission_name',          '23514 permission_name_shape', '42501',
                                                           '23514 permission_name_shape', '42501'),
    (2,  'prefix', 'entities.id_prefix',                   '23514 valid_id_prefix', '42501',
                                                           '23514 valid_id_prefix', '42501'),
    (3,  'vcode',  'the code of a validation rule',        '90905', '42501', '90905', '42501'),
    (4,  'cname',  'the name of a computed field',         'accepted', '42501', 'accepted', '42501'),
    (5,  'reft',   'fields.reference_table',               '90212', '90212', '90212', '90212'),
    (6,  'queue',  'queues.queue_name',                    '90505', '42501', 'accepted', '42501'),
    (7,  'rlink',  'the link_field of a rollup',           '90262', '90262', '90262', '90262'),
    (8,  'rfunc',  'the function of a rollup',             '90263', '90263', '90263', '90263'),
    (9,  'rvalue', 'the value_field of a rollup',          '90264', '90264', '90264', '90264'),
    (10, 'rvar',   'a var in a rollup filter',             '90265', '42501', '90265', '42501'),
    (11, 'rlit',   'a literal in a rollup filter',         'accepted', '42501', 'accepted', '42501'),
    (12, 'mname',  'modules.module_name',                  'accepted', '42501', 'accepted', '42501'),
    (13, 'mslug',  'modules.module_slug',                  '90702', '90702', '90702', '90702'),
    (14, 'rname',  'roles.role_name',                      'accepted', '42501', 'accepted', '42501'),
    (15, 'pgmq',   'pgmq.convert_archive_partitioned',     '42501', '42501', '42501', '42501'),
    (16, 'qtable', 'queue_table_events.table_name',        '23503', '42501', '23503', '42501'),
    (17, 'gate',   'process_gates.entity',                 '23503', '42501', '23503', '42501'),
    (18, 'qread',  'the conditional of pgmq.read',         '42501', '42501', '42501', '42501'),
    (19, 'rcmp',   'the operator of a rollup filter',      '90265', '42501', '90265', '42501'),
    (20, 'rdop',   'an operator used as a value in a rollup filter',
                                                           '90265', '42501', '90265', '42501'),
    (21, 'tname',  'entities.table_name',                  '90273', '90273', '23514 valid_table_name', '42501'),
    (22, 'tren',   'entities.table_name, renamed',         '90273', 'P0002', '23514 valid_table_name', 'P0002'),
    (23, 'idcol',  'entities.id_column',                   '23514 valid_id_column', '42501',
                                                           '23514 valid_id_column', '42501'),
    (24, 'ensure', 'public.ensure_entities',               '42501', '42501', '42501', '42501');

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

-- The entity every rename aims at, the queue every mapping and read names,
-- and the process every gate belongs to. The ids are read here, once, so a
-- plain user's statement does not depend on which of the rows it may read:
-- an INSERT ... SELECT that finds no row inserts nothing and passes for
-- accepted.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('s1_ren', 'Ren', 'Rens', 1, 'public:read', 'admin');
INSERT INTO queues (queue_name) VALUES ('s1_q');
SELECT set_config('test.s1_queue', (SELECT id::text FROM queues WHERE queue_name = 's1_q'), true);
INSERT INTO processes (module_id, process_key, name, description, ordering)
VALUES (1, 's1_gates', 'S1 Gates', 'probe', 10);
SELECT set_config('test.s1_process', (SELECT id::text FROM processes WHERE process_key = 's1_gates'), true);
SELECT set_config('test.s1_raci_triggers',
    (SELECT count(*)::text FROM pg_catalog.pg_trigger WHERE tgname ~ '^(a_)?raci_(gate|emit)_on_'), true);

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'a' || p.n, p.val)), c.as_admin,
          format('%s, as an administrator: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_payloads ORDER BY n) p;

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'a' || p.n, p.val)), c.quiet_admin,
          format('%s, as an administrator: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_quiet ORDER BY n) p;

-- What was accepted is text now. Running what was generated from it must not
-- run it: a write to every entity built above, and a child under the parent
-- whose rollups hold the literals.
SELECT pg_temp.s1_try(format('INSERT INTO public.%I (label) VALUES (%L)', e.table_name, 'x'))
  FROM entities e
 WHERE e.table_name LIKE 's1\_cname\_%' OR e.table_name LIKE 's1\_vcode\_%' OR e.table_name LIKE 's1\_prefix\_%';
SELECT pg_temp.s1_try($$INSERT INTO s1_child (label, parent_id, amount) SELECT 'x', id, 1 FROM s1_parent$$);

-- And it is the text it was: stored byte for byte as written.
SELECT is(pg_temp.s1_value(pg_temp.s1_stored_sql(a.code, 'a' || a.n, a.val)), a.val,
          format('%s, as an administrator: %s is stored as written', a.place, a.kind))
  FROM (SELECT c.ord, c.code, c.place, p.n, p.kind, p.val
          FROM s1_cases c JOIN s1_payloads p ON c.as_admin = 'accepted'
        UNION ALL
        SELECT c.ord, c.code, c.place, p.n, p.kind, p.val
          FROM s1_cases c JOIN s1_quiet p ON c.quiet_admin = 'accepted'
         ORDER BY ord, n) a;

-- The rule function generated from a computed field name carries the name as
-- one quoted literal, and the entity it belongs to took the record above.
SELECT is(pg_temp.s1_value(format(
              $q$SELECT concat_ws(' ', position(%L IN p.prosrc) > 0, (SELECT count(*) FROM public.%I))
                   FROM pg_catalog.pg_proc p WHERE p.oid = to_regprocedure(%L)$q$,
              quote_literal(p.val), 's1_cname_a' || p.n,
              format('common.%I(text, jsonb, jsonb)', 'record_rules_s1_cname_a' || p.n))),
          't 1',
          format('the name of a computed field, as an administrator: %s is a literal of the rule function, and the entity takes a record',
                 p.kind))
  FROM (SELECT * FROM s1_payloads UNION ALL SELECT * FROM s1_quiet ORDER BY n) p;

-- A filter literal is compared as the text it is: the rollup over each one
-- counts the one child whose label is that value, and not the child x above.
SELECT pg_temp.s1_try($$INSERT INTO s1_child (label, parent_id, amount)
                        SELECT p.val, s.id, 1
                          FROM (SELECT val FROM s1_payloads UNION ALL SELECT val FROM s1_quiet) p
                         CROSS JOIN s1_parent s$$);
SELECT is(pg_temp.s1_value(format('SELECT %I FROM s1_parent', 'rlit_a' || p.n)), '1',
          format('a literal in a rollup filter, as an administrator: %s counts the one child labeled with it', p.kind))
  FROM (SELECT * FROM s1_payloads UNION ALL SELECT * FROM s1_quiet ORDER BY n) p;

-- A queue under each accepted name works on every path that builds a
-- statement from the name: a table mapped to it gets its trigger and sends a
-- message on insert, queue_read reads it, and deleting the queue drops the
-- trigger of the mapping and the tables of the queue.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
SELECT 's1_qmap_a' || n, 'Mapped', 'Mappeds', 1, 'public:read', 'admin' FROM s1_quiet;
SELECT pg_temp.s1_try(format(
           $q$INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
              SELECT id, 'mapped', %L, 'insert' FROM queues WHERE queue_name = %L$q$,
           's1_qmap_a' || n, val))
  FROM s1_quiet;
SELECT pg_temp.s1_try(format('INSERT INTO public.%I (label) VALUES (%L)', 's1_qmap_a' || n, 'm')) FROM s1_quiet;
SELECT is(pg_temp.s1_value(format($q$SELECT queue_read(%L, 0, 10) -> 0 -> 'message' ->> 'table'$q$, p.val)),
          's1_qmap_a' || p.n,
          format('queues.queue_name, as an administrator: a table mapped to the queue %s sends to it, and queue_read reads it',
                 p.kind))
  FROM (SELECT * FROM s1_quiet ORDER BY n) p;
SELECT pg_temp.s1_try(format('DELETE FROM queues WHERE queue_name = %L', val)) FROM s1_quiet;
SELECT is(concat_ws(' ', to_regclass(format('pgmq.%I', 'q_' || p.val)) IS NULL,
                         to_regclass(format('pgmq.%I', 'a_' || p.val)) IS NULL,
                         (SELECT count(*) FROM pg_catalog.pg_trigger t
                           WHERE t.tgrelid = to_regclass(format('public.%I', 's1_qmap_a' || p.n))
                             AND t.tgname LIKE 'queue\_%')),
          't t 0',
          format('and deleting the queue %s drops the trigger of its mapping and its tables', p.kind))
  FROM (SELECT * FROM s1_quiet ORDER BY n) p;

SELECT authenticate_as('user1');

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'u' || p.n, p.val)), c.as_user,
          format('%s, as a plain user: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_payloads ORDER BY n) p;

SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(c.code, 'u' || p.n, p.val)), c.quiet_user,
          format('%s, as a plain user: %s', c.place, p.kind))
  FROM (SELECT * FROM s1_cases ORDER BY ord) c
 CROSS JOIN LATERAL (SELECT * FROM s1_quiet ORDER BY n) p;

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
SELECT is((SELECT last_value || ' ' || is_called FROM public.s1_hits), '1 true',
    'no value ran as SQL: s1_hit was called by the check above only');
-- A gate names an entity, a foreign key: none of these names is one, so no
-- gate was stored and no trigger was built from them.
SELECT is((SELECT count(*)::text FROM pg_catalog.pg_trigger WHERE tgname ~ '^(a_)?raci_(gate|emit)_on_'),
    current_setting('test.s1_raci_triggers'),
    'no process gate built a trigger from the entity it names');
SELECT is(concat_ws(' ', (SELECT count(*) FROM entities WHERE table_name = 's1_ren'),
                         to_regclass('public.s1_ren') IS NOT NULL),
    '1 t',
    'the entity the refused renames aimed at keeps its name and its table');

-- The paths no caller reaches. ensure_entities and its two helpers build
-- their statements from the keys of a definition document and are run only
-- by the installer, on the text of a migration file: the request role may
-- not execute them, and no definer function calls them for it. Run by the
-- installer, they refuse a hostile key before any statement is built from it.
SELECT ok(NOT (has_function_privilege('semantius_user', 'public.ensure_entities(jsonb)', 'EXECUTE')
            OR has_function_privilege('semantius_user', 'public.ensure_entities_row(text, jsonb, jsonb, text[], text)', 'EXECUTE')
            OR has_function_privilege('semantius_user', 'public.ensure_entities_insert_rows(text, jsonb)', 'EXECUTE')),
    'the request role may execute neither ensure_entities nor its two helpers');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.prosecdef AND p.prosrc ~ 'ensure_entities'),
    'and no definer function calls them for it');
SELECT is(pg_temp.s1_outcome(pg_temp.s1_sql(r.code, 'i' || r.n, r.val)), '22023',
          format('%s, as the installer: %s is refused', r.place, r.kind))
  FROM (SELECT s.ord, s.code, s.place, p.n, p.kind, p.val
          FROM (VALUES (1, 'ensure', 'a key of the module of a definition'),
                       (2, 'erec',   'a key of a record of a definition')) AS s(ord, code, place)
         CROSS JOIN (SELECT * FROM s1_payloads UNION ALL SELECT * FROM s1_quiet) p
         ORDER BY s.ord, p.n) r;

-- pgmq.read splices its conditional with %L. The request role may call it
-- and was refused the queue table above, after the statement was built; the
-- installer, who may read the table, finds with a conditional made of each
-- value the one message that carries it.
SELECT pg_temp.s1_try(format('SELECT pgmq.send(%L, %L::jsonb)', 's1_q', jsonb_build_object('k', p.val)))
  FROM (SELECT * FROM s1_payloads UNION ALL SELECT * FROM s1_quiet ORDER BY n) p;
SELECT is(pg_temp.s1_value(format(
              $q$SELECT string_agg(message ->> 'k', ',') FROM pgmq.read('s1_q', 0, 10, jsonb_build_object('k', %L))$q$,
              p.val)),
          p.val,
          format('the conditional of pgmq.read, as the installer: %s finds the one message that carries it', p.kind))
  FROM (SELECT * FROM s1_payloads UNION ALL SELECT * FROM s1_quiet ORDER BY n) p;

-- pgmq.create_partitioned splices its partition and retention intervals with
-- %L, and pgmq.convert_archive_partitioned its own. Semantius code calls
-- neither, convert_archive_partitioned is revoked from PUBLIC (the pgmq case
-- above), and create_partitioned creates the queue table in schema pgmq
-- before it splices an interval, which the request role, though it may call
-- the function, has no privilege to do. The schemas of the Semantius code are
-- named rather than every schema but pgmq: the installer of the extension
-- build, semantius.migrate, carries the text of every migration, pgmq's own
-- included, and calls none of it.
SELECT ok(NOT has_schema_privilege('semantius_user', 'pgmq', 'CREATE'),
    'the request role cannot create the table pgmq.create_partitioned builds before it splices an interval');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname IN ('public', 'common', 'rbac', 'audit')
                         AND p.prosrc ~ '(create_partitioned|convert_archive_partitioned)'),
    'and no function of the Semantius code calls create_partitioned or convert_archive_partitioned');

-- queue_event_after_delete builds its statements from the table_name of the
-- mapping being deleted: what the foreign key accepted when it was written,
-- which the qtable case shows refusing every hostile value.
SELECT is((SELECT confrelid::regclass::text FROM pg_catalog.pg_constraint
            WHERE conrelid = 'public.queue_table_events'::regclass AND conname = 'queue_table_events_table_name_fkey'),
    'entities',
    'the table of a queue mapping is a foreign key to entities, so a mapping that is deleted names an entity');

-- The installer's runs above sent every payload as well, after the count was
-- last taken, so it is taken once more.
SELECT is((SELECT last_value || ' ' || is_called FROM public.s1_hits), '1 true',
    'no value ran as SQL in the installer''s runs either');

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

-- A gate is installed as a trigger on the table its row names, which has to
-- be an entity (the foreign key of process_gates.entity): an internal table
-- is not one.
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

-- pgmq allows 47 characters and counts them as characters, while
-- PostgreSQL cuts a table name at 63 bytes, so two long names of multi-byte
-- characters would share their tables. The limit is 47 bytes: archived_at_idx_
-- and the name fill exactly 63.
SELECT is(pg_temp.s1_outcome(format($q$INSERT INTO queues (queue_name) VALUES (%L)$q$, repeat(U&'\00e9', 24))),
    '90505',
    'a queue name of 24 two-byte characters, 48 bytes, is refused');
SELECT is(pg_temp.s1_outcome(format($q$INSERT INTO queues (queue_name) VALUES (%L)$q$, repeat(U&'\00e9', 23) || 'x')),
    'accepted',
    'and one of 47 bytes is accepted');

-- A table mapped to a queue gets triggers named queue_<queue>_<event>_on_
-- <table>. A name cut at 63 bytes is one the rename of the table and the
-- removal of the mapping no longer find, so the mapping is refused.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('s1_mapped_' || repeat('t', 30), 'Mapped', 'Mappeds', 1, 'public:read', 'admin');
INSERT INTO queues (queue_name) VALUES ('s1_queue_' || repeat('q', 30));
SELECT is(
    pg_temp.s1_outcome(format(
        $q$INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
           SELECT id, 'too long together', %L, 'insert' FROM queues WHERE queue_name = %L$q$,
        's1_mapped_' || repeat('t', 30), 's1_queue_' || repeat('q', 30))),
    '90506',
    'a queue mapping whose trigger name would not fit 63 bytes is refused');

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

-- What keeps it that way is asserted with the other security facts, in
-- 0900_test_security.sql: every function that pins a search_path lists
-- pg_temp last.

SELECT * FROM finish();
ROLLBACK;
