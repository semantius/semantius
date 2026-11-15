-- =====================================================
-- Identifier and metadata hardening (0535)
-- =====================================================
-- Every name and every text an administrator writes into entities and fields
-- ends up in DDL the dictionary runs as the owner: table, column, index,
-- policy and trigger names, comments, CHECK lists, column defaults and the
-- bodies of generated functions. This file feeds each of those places text
-- that is harmless as data and hostile as SQL, and asserts that it is either
-- refused before any DDL keeps it or carried through as the text it is.
-- Defaults and rule text are covered by 0530_test_default_value_hardening.sql.
--
--   PART 1  the identifier columns take nothing outside [a-z_][a-z0-9_]*
--   PART 2  table names at and beyond PostgreSQL's 63-byte limit
--   PART 3  generated index names that two entities share
--   PART 4  SQL reserved words as entity and field names
--   PART 5  quotes, percent and dollar signs and backslashes in metadata
--   PART 6  a dollar-quote tag in a column default of a has_a base
--
-- Every case works on names of its own, so a statement that is accepted where
-- a refusal is expected changes nothing for the cases after it. user3, an
-- administrator, makes the dictionary changes. Everything is rolled back.
BEGIN;

SELECT plan(245);

-- =====================================================
-- Helpers
-- =====================================================
-- pg_temp functions run as whichever user the test authenticated as: a
-- function outside public and common keeps the PUBLIC execute default.

-- What a statement is refused with: its SQLSTATE followed by the CHECK
-- constraint its message names, or by the whole message when it names none.
-- 'accepted' when it is not refused. With p_undo an accepted statement is
-- rolled back, for a statement that would rename the fixture the next case
-- needs.
CREATE FUNCTION pg_temp.idh_refusal(p_sql TEXT, p_undo BOOLEAN DEFAULT FALSE) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_state   TEXT;
    v_message TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        IF NOT p_undo THEN
            RETURN 'accepted';
        END IF;
        RAISE EXCEPTION 'accepted' USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    END;
    IF v_state = 'ZZ001' THEN
        RETURN 'accepted';
    END IF;
    RETURN v_state || ' ' || coalesce(substring(v_message FROM 'check constraint "([^"]+)"'), v_message);
END $f$;

-- The one value a query returns, as text: 'NULL' for none, and the error
-- instead of the value when the query fails, so an assertion on a relation
-- that was never built fails instead of ending the file.
CREATE FUNCTION pg_temp.idh_value(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_value TEXT;
BEGIN
    EXECUTE p_sql INTO v_value;
    RETURN coalesce(v_value, 'NULL');
EXCEPTION WHEN OTHERS THEN
    RETURN format('ERROR %s: %s', SQLSTATE, SQLERRM);
END $f$;

-- =====================================================
-- PART 1: identifier columns
-- =====================================================
-- A name in one of these columns is interpolated into CREATE TABLE, ALTER
-- TABLE, CREATE INDEX, CREATE POLICY and CREATE TRIGGER, and concatenated
-- into the names of generated objects. The CHECK constraints of entities and
-- fields are what keeps everything but [a-z_][a-z0-9_]* out, whichever path
-- the name arrives on.

-- One character outside the grammar per case, and one value that would end
-- the statement it is interpolated into and create a role.
CREATE TEMP TABLE idh_cases (n INT PRIMARY KEY, kind TEXT NOT NULL, val TEXT NOT NULL);
GRANT SELECT ON idh_cases TO semantius_user;
INSERT INTO idh_cases VALUES
    (1,  'a double quote',                  'idh_a"b'),
    (2,  'a single quote',                  'idh_a''b'),
    (3,  'a semicolon',                     'idh_a;b'),
    (4,  'a space',                         'idh_a b'),
    (5,  'an uppercase letter',             'idh_aBc'),
    (6,  'a hyphen',                        'idh_a-b'),
    (7,  'a dot',                           'idh_a.b'),
    (8,  'a dollar sign',                   'idh_a$b'),
    (9,  'a non-ASCII letter',              U&'idh_\00e9'),
    (10, 'a leading digit',                 '1idh_a'),
    (11, 'a trailing newline',              E'idh_a\n'),
    (12, 'a statement that creates a role', 'x"); CREATE ROLE idh_pwned SUPERUSER; --');

-- The INSERT that puts p_value into p_column: a field of idh_probe for
-- field_name, else a new entity, named after the case unless the table name
-- is the column under test.
CREATE FUNCTION pg_temp.idh_insert_sql(p_tag TEXT, p_column TEXT, p_n INT, p_value TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT CASE WHEN p_column = 'field_name' THEN
               format($q$INSERT INTO fields (table_name, field_name, title, format)
                         VALUES ('idh_probe', %L, 'Hostile', 'text')$q$, p_value)
           ELSE
               format($q$INSERT INTO entities (table_name, singular_label, plural_label, module_id,
                                               view_permission, edit_permission,
                                               id_column, label_column, label_parent, order_column)
                         VALUES (%L, 'Hostile', 'Hostiles', 1, 'public:read', 'admin', %L, %L, %L, %L)$q$,
                      CASE WHEN p_column = 'table_name' THEN p_value
                           ELSE format('idh_%s_%s_%s', p_tag, p_n, p_column) END,
                      CASE WHEN p_column = 'id_column' THEN p_value ELSE 'id' END,
                      CASE WHEN p_column = 'label_column' THEN p_value ELSE 'label' END,
                      CASE WHEN p_column = 'label_parent' THEN p_value ELSE '' END,
                      CASE WHEN p_column = 'order_column' THEN p_value ELSE '' END)
           END;
$f$;

-- The UPDATE that puts p_value into p_column of idh_probe, or renames its
-- field note for field_name.
CREATE FUNCTION pg_temp.idh_update_sql(p_column TEXT, p_value TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT CASE WHEN p_column = 'field_name' THEN
               format($q$UPDATE fields SET field_name = %L
                          WHERE table_name = 'idh_probe' AND field_name = 'note'$q$, p_value)
           ELSE
               format($q$UPDATE entities SET %I = %L WHERE table_name = 'idh_probe'$q$, p_column, p_value)
           END;
$f$;

-- label_parent has two guards. validate_label_parent_trigger runs first and
-- refuses a name that no field of the entity carries (90226), and no field
-- can carry one of these names, so no request ever reaches
-- valid_label_parent; the CHECK is what remains when the trigger is not
-- there. It is asserted on its own here, with the trigger switched off by the
-- owner, and the trigger's refusal with the other columns below.
ALTER TABLE entities DISABLE TRIGGER validate_label_parent_trigger;

SELECT is(pg_temp.idh_refusal(pg_temp.idh_insert_sql('chk', 'label_parent', c.n, c.val)),
          '23514 valid_label_parent',
          format('entities.label_parent, the CHECK alone: %s is refused', c.kind))
  FROM (SELECT * FROM idh_cases ORDER BY n) c;

ALTER TABLE entities ENABLE TRIGGER validate_label_parent_trigger;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('idh_probe', 'Probe', 'Probes', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format)
VALUES ('idh_probe', 'note', 'Note', 'text');
INSERT INTO idh_probe (label, note) VALUES ('kept', 'kept');

-- A new entity or field under the name.
SELECT is(pg_temp.idh_refusal(pg_temp.idh_insert_sql('ins', m.col, m.n, m.val)),
          m.refusal,
          format('%s on insert: %s is refused', m.col_label, m.kind))
  FROM (SELECT t.col, t.col_label, t.refusal, c.n, c.kind, c.val
          FROM (VALUES
                (1, 'table_name',   'entities.table_name',   '23514 valid_table_name'),
                (2, 'id_column',    'entities.id_column',    '23514 valid_id_column'),
                (3, 'label_column', 'entities.label_column', '23514 valid_label_column'),
                (4, 'label_parent', 'entities.label_parent', '90226 label_parent ${label_parent} is not a field of entity ${table}'),
                (5, 'order_column', 'entities.order_column', '23514 valid_order_column'),
                (6, 'field_name',   'fields.field_name',     '23514 valid_field_name')
               ) AS t(ord, col, col_label, refusal)
         CROSS JOIN idh_cases c
         ORDER BY t.ord, c.n) m;

-- An existing entity or field renamed to it. rename_table_trigger is a BEFORE
-- trigger, so the table carries the new name by the time the CHECK refuses the
-- row: the refusal is also what undoes that rename. id_column is not here
-- because it cannot change at all (90253).
SELECT is(pg_temp.idh_refusal(pg_temp.idh_update_sql(m.col, m.val), TRUE),
          m.refusal,
          format('%s on update: %s is refused', m.col_label, m.kind))
  FROM (SELECT t.col, t.col_label, t.refusal, c.n, c.kind, c.val
          FROM (VALUES
                (1, 'table_name',   'entities.table_name',   '23514 valid_table_name'),
                (2, 'label_column', 'entities.label_column', '23514 valid_label_column'),
                (3, 'order_column', 'entities.order_column', '23514 valid_order_column'),
                (4, 'field_name',   'fields.field_name',     '23514 valid_field_name')
               ) AS t(ord, col, col_label, refusal)
         CROSS JOIN idh_cases c
         ORDER BY t.ord, c.n) m;

-- Nothing the attempts named exists.
SELECT is((SELECT count(*)::int FROM pg_roles WHERE rolname LIKE 'idh%'), 0,
    'no role was created by a refused name');
SELECT is((SELECT count(*)::int FROM pg_class c
            WHERE c.relname LIKE 'idh\_ins\_%' OR c.relname LIKE 'idh\_chk\_%'
               OR c.relname::text IN (SELECT val FROM idh_cases)), 0,
    'no relation was created for a refused entity or under a refused name');
SELECT is((SELECT count(*)::int FROM pg_attribute a
            WHERE a.attname::text IN (SELECT val FROM idh_cases)), 0,
    'no column carries a refused name');
SELECT is((SELECT count(*)::int FROM entities e
            WHERE e.table_name LIKE 'idh\_ins\_%' OR e.table_name LIKE 'idh\_chk\_%'
               OR EXISTS (SELECT 1 FROM idh_cases c
                           WHERE c.val IN (e.table_name, e.id_column, e.label_column, e.label_parent, e.order_column)))
        + (SELECT count(*)::int FROM fields f WHERE f.field_name IN (SELECT val FROM idh_cases)), 0,
    'no dictionary row holds a refused name');
SELECT is(pg_temp.idh_value($$
        SELECT concat_ws(' ', e.table_name, e.label_column, quote_literal(e.order_column),
                         (SELECT string_agg(f.field_name, ',' ORDER BY f.field_order)
                            FROM fields f WHERE f.table_name = e.table_name),
                         (SELECT count(*) FROM idh_probe WHERE note = 'kept'))
          FROM entities e WHERE e.table_name = 'idh_probe'$$),
    $$idh_probe label '' id,label,note,created_at,updated_at 1$$,
    'the entity the refused renames aimed at keeps its name, its columns and its row');

-- =====================================================
-- PART 2: long table names
-- =====================================================
-- PostgreSQL stores 63 bytes of a name and cuts the rest without an error, so
-- a longer table_name can never be the name of the entity's table, and two
-- names that differ only after byte 63 are one table. The names generated
-- from a table name (<t>_select_policy, update_<t>_updated_at, ...) are cut
-- the same way, and the longest of them puts 22 bytes around the table name.
-- So the dictionary refuses a table name of more than 41 bytes itself, with a
-- code of its own, before anything is built from it.

-- 'refused <code>' for a refusal by a CHECK or with a dictionary code (class
-- 90), 'usable' when the entity is created, its table carries exactly p_table
-- and a row written under that name is read back, else what happened instead.
CREATE FUNCTION pg_temp.idh_entity_outcome(p_table TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_state   TEXT;
    v_message TEXT;
    v_count   INT;
BEGIN
    BEGIN
        EXECUTE format($q$INSERT INTO entities (table_name, singular_label, plural_label, module_id,
                                                view_permission, edit_permission)
                          VALUES (%L, 'Long', 'Longs', 1, 'public:read', 'admin')$q$, p_table);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        RETURN CASE WHEN v_state = '23514' OR v_state LIKE '90%' THEN 'refused ' || v_state
                    ELSE format('the entity fails with %s: %s', v_state, v_message) END;
    END;
    IF NOT EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relname::text = p_table AND c.relnamespace = 'public'::regnamespace) THEN
        RETURN 'created, but no table carries the name';
    END IF;
    BEGIN
        EXECUTE format('INSERT INTO public.%I (label) VALUES (%L)', p_table, p_table);
        EXECUTE format('SELECT count(*) FROM public.%I WHERE label = %L', p_table, p_table) INTO v_count;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        RETURN format('created, but a write fails with %s: %s', v_state, v_message);
    END;
    RETURN CASE WHEN v_count = 1 THEN 'usable' ELSE format('created, but %s rows are read back', v_count) END;
END $f$;

SELECT is(pg_temp.idh_entity_outcome('idh_fits_' || repeat('a', 32)), 'usable',
    'a 41-byte table name, the longest whose generated names all fit, builds a usable entity');
SELECT is(pg_temp.idh_entity_outcome('idh_over_' || repeat('a', 33)), 'refused 90273',
    'a 42-byte table name is refused by the dictionary');
SELECT is(pg_temp.idh_entity_outcome('idh_edge_' || repeat('a', 54)), 'refused 90273',
    'a 63-byte table name, the longest PostgreSQL stores, is refused by the dictionary');
SELECT is(pg_temp.idh_entity_outcome('idh_long_' || repeat('a', 55)), 'refused 90273',
    'a 64-byte table name is refused by the dictionary');
SELECT is(pg_temp.idh_entity_outcome('idh_twin_' || repeat('a', 54) || 'x'), 'refused 90273',
    'the first of two table names that share their first 63 bytes is refused by the dictionary');
SELECT is(pg_temp.idh_entity_outcome('idh_twin_' || repeat('a', 54) || 'y'), 'refused 90273',
    'the second of two table names that share their first 63 bytes is refused by the dictionary');
SELECT is((SELECT count(*)::int FROM pg_class c
            WHERE c.relname::text IN ('idh_long_' || repeat('a', 54), 'idh_twin_' || repeat('a', 54))), 0,
    'no table is left under the 63 bytes a longer name is cut to');

-- =====================================================
-- PART 3: generated index names that two entities share
-- =====================================================
-- The unique index of a field is named <table>_<field>_unique and the index
-- of a reference field idx_<table>_<field>. Index names are unique in the
-- schema, and table a_b with field c spells the same name as table a with
-- field b_c. The first field gets its index and the second one is refused; an
-- index is never created for one and counted for both.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('idh_u_b', 'Left', 'Lefts', 1, 'public:read', 'admin'),
       ('idh_u',   'Right', 'Rights', 1, 'public:read', 'admin'),
       ('idh_r_b', 'Left', 'Lefts', 1, 'public:read', 'admin'),
       ('idh_r',   'Right', 'Rights', 1, 'public:read', 'admin');

-- Adds a unique text field: 'refused <code>' for a refusal by a CHECK or with a
-- dictionary code, 'enforced' when a second row with the same value raises
-- 23505, else what happened instead. The first row stays.
CREATE FUNCTION pg_temp.idh_unique_field(p_table TEXT, p_field TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_state   TEXT;
    v_message TEXT;
BEGIN
    BEGIN
        EXECUTE format($q$INSERT INTO fields (table_name, field_name, title, format, unique_value)
                          VALUES (%L, %L, 'Code', 'text', TRUE)$q$, p_table, p_field);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        RETURN CASE WHEN v_state = '23514' OR v_state LIKE '90%' THEN 'refused ' || v_state
                    ELSE format('the field fails with %s: %s', v_state, v_message) END;
    END;
    BEGIN
        EXECUTE format($q$INSERT INTO public.%I (label, %I) VALUES ('first', 'same')$q$, p_table, p_field);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        RETURN format('created, but a write fails with %s: %s', v_state, v_message);
    END;
    BEGIN
        EXECUTE format($q$INSERT INTO public.%I (label, %I) VALUES ('second', 'same')$q$, p_table, p_field);
    EXCEPTION
        WHEN unique_violation THEN
            RETURN 'enforced';
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
            RETURN format('created, but a write fails with %s: %s', v_state, v_message);
    END;
    RETURN 'created, but a second row with the same value is accepted';
END $f$;

-- The number of indexes of p_table whose leading column is p_field.
CREATE FUNCTION pg_temp.idh_index_count(p_table TEXT, p_field TEXT) RETURNS INT LANGUAGE sql AS $f$
    SELECT count(*)::int
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
     WHERE i.indrelid = to_regclass(format('public.%I', p_table))
       AND a.attname = p_field;
$f$;

-- Adds a reference field to idh_probe: 'refused <code>' for a refusal by a CHECK
-- or with a dictionary code, 'indexed' when the column has its index, else what
-- happened instead.
CREATE FUNCTION pg_temp.idh_reference_field(p_table TEXT, p_field TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_state   TEXT;
    v_message TEXT;
BEGIN
    BEGIN
        EXECUTE format($q$INSERT INTO fields (table_name, field_name, title, format, reference_table)
                          VALUES (%L, %L, 'Probe', 'reference', 'idh_probe')$q$, p_table, p_field);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
        RETURN CASE WHEN v_state = '23514' OR v_state LIKE '90%' THEN 'refused ' || v_state
                    ELSE format('the field fails with %s: %s', v_state, v_message) END;
    END;
    RETURN CASE WHEN pg_temp.idh_index_count(p_table, p_field) = 1 THEN 'indexed'
                ELSE 'created, but the column has no index' END;
END $f$;

SELECT is(pg_temp.idh_unique_field('idh_u_b', 'c'), 'enforced',
    'unique field c of idh_u_b: its uniqueness is enforced');
SELECT is(pg_temp.idh_unique_field('idh_u', 'b_c'), 'refused 90274',
    'unique field b_c of idh_u, whose index name idh_u_b.c took: refused');
-- Dropping the rule of one field leaves the rule of the other.
SELECT lives_ok($$UPDATE fields SET unique_value = FALSE WHERE table_name = 'idh_u' AND field_name = 'b_c'$$,
    'unique_value of idh_u.b_c is turned off');
-- The drop itself, asked to remove that name for the other table: it looks at
-- whose index carries the name, and leaves one that is not the table's own.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(dd_drop_own_index('idh_u', 'idh_u_b_c_unique'), FALSE,
    'a drop of idh_u_b_c_unique for idh_u removes nothing: the index is on idh_u_b');
SELECT authenticate_as('user3');
SELECT is(catch_error($$INSERT INTO idh_u_b (label, c) VALUES ('third', 'same')$$) ->> 'code', '23505',
    'idh_u_b.c is still unique after idh_u.b_c stopped being unique');

SELECT is(pg_temp.idh_reference_field('idh_r_b', 'c'), 'indexed',
    'reference field c of idh_r_b: the column is indexed');
SELECT is(pg_temp.idh_reference_field('idh_r', 'b_c'), 'refused 90274',
    'reference field b_c of idh_r, whose index name idh_r_b.c took: refused');
-- Deleting one field leaves the index of the other.
SELECT lives_ok($$DELETE FROM fields WHERE table_name = 'idh_r' AND field_name = 'b_c'$$,
    'field b_c of idh_r is deleted');
SELECT is(pg_temp.idh_index_count('idh_r_b', 'c'), 1,
    'idh_r_b.c keeps its index after idh_r.b_c is deleted');

-- =====================================================
-- PART 4: reserved words
-- =====================================================
-- user, order, select and group cannot be written unquoted. The grammar of
-- the identifier columns allows them, so every statement the dictionary
-- generates has to quote the name: one that does not fails here on the
-- keyword. Each word is the name of an entity and of a field of it, taken
-- through its whole life: create, write, read, rename away and back (the word
-- as the old and as the new name), delete.
CREATE FUNCTION pg_temp.idh_reserved_word(w TEXT) RETURNS SETOF TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_other TEXT := 'idh_was_' || w;
BEGIN
    RETURN NEXT lives_ok(format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
           VALUES (%L, 'Word', 'Words', 1, 'public:read', 'admin')$q$, w),
        format('%s: an entity of that name is created', w));
    RETURN NEXT lives_ok(format(
        $q$INSERT INTO fields (table_name, field_name, title, format) VALUES (%L, %L, 'Word', 'text')$q$, w, w),
        format('%s: a field of that name is added to it', w));
    RETURN NEXT lives_ok(format($q$INSERT INTO public.%I (label, %I) VALUES ('first', 'written')$q$, w, w),
        format('%s: a row is inserted', w));
    RETURN NEXT is(pg_temp.idh_value(format($q$SELECT %I FROM public.%I WHERE label = 'first'$q$, w, w)), 'written',
        format('%s: the row is read back', w));
    RETURN NEXT lives_ok(format(
        $q$UPDATE fields SET field_name = %L WHERE table_name = %L AND field_name = %L$q$, v_other, w, w),
        format('%s: the field is renamed to another name', w));
    RETURN NEXT lives_ok(format(
        $q$UPDATE fields SET field_name = %L WHERE table_name = %L AND field_name = %L$q$, w, w, v_other),
        format('%s: a field is renamed to it', w));
    RETURN NEXT lives_ok(format($q$UPDATE entities SET table_name = %L WHERE table_name = %L$q$, v_other, w),
        format('%s: the entity is renamed to another name', w));
    RETURN NEXT lives_ok(format($q$UPDATE entities SET table_name = %L WHERE table_name = %L$q$, w, v_other),
        format('%s: an entity is renamed to it', w));
    RETURN NEXT is(pg_temp.idh_value(format($q$SELECT %I FROM public.%I WHERE label = 'first'$q$, w, w)), 'written',
        format('%s: the row is read back after the renames', w));
    RETURN NEXT lives_ok(format($q$DELETE FROM public.%I WHERE label = 'first'$q$, w),
        format('%s: the row is deleted', w));
    RETURN NEXT lives_ok(format($q$DELETE FROM fields WHERE table_name = %L AND field_name = %L$q$, w, w),
        format('%s: the field is deleted', w));
    RETURN NEXT lives_ok(format($q$DELETE FROM entities WHERE table_name = %L$q$, w),
        format('%s: the entity is deleted', w));
    RETURN NEXT ok(to_regclass(format('public.%I', w)) IS NULL,
        format('%s: its table is gone', w));
END $f$;

SELECT pg_temp.idh_reserved_word('user');
SELECT pg_temp.idh_reserved_word('order');
SELECT pg_temp.idh_reserved_word('select');
SELECT pg_temp.idh_reserved_word('group');

-- =====================================================
-- PART 5: metadata text
-- =====================================================
-- Labels, titles, descriptions and enum values are free text that the
-- dictionary writes into COMMENT ON, into the list of an enum CHECK and into
-- get_schema. A quote, a percent sign (the placeholder of format() and of
-- RAISE), a dollar sign, a backslash and a double quote arrive as they were
-- written, each of them in every one of those places.
CREATE TEMP TABLE idh_texts (n INT PRIMARY KEY, val TEXT NOT NULL);
GRANT SELECT ON idh_texts TO semantius_user;
INSERT INTO idh_texts VALUES
    (1, 'O''Brien'),
    (2, '50%'),
    (3, 'a$b$'),
    (4, 'back\slash'),
    (5, '"quoted"');

-- A text that starts with p_lead and holds all five.
CREATE FUNCTION pg_temp.idh_text(p_lead TEXT) RETURNS TEXT LANGUAGE sql AS $f$
    SELECT p_lead || ' ' || string_agg(val, ' ' ORDER BY n) FROM idh_texts;
$f$;

SELECT lives_ok(format(
    $q$INSERT INTO entities (table_name, singular_label, plural_label, description, module_id,
                             view_permission, edit_permission)
       VALUES ('idh_meta', %L, %L, %L, 1, 'public:read', 'admin')$q$,
    pg_temp.idh_text('One'), pg_temp.idh_text('Many'), pg_temp.idh_text('About')),
    'an entity whose labels and description hold the five texts builds');
SELECT lives_ok(format(
    $q$INSERT INTO fields (table_name, field_name, title, description, format, enum_values)
       VALUES ('idh_meta', 'kind', %L, %L, 'enum', %L::jsonb)$q$,
    pg_temp.idh_text('Kind'), pg_temp.idh_text('Which'), (SELECT jsonb_agg(val ORDER BY n) FROM idh_texts)),
    'an enum field whose title, description and values are the five texts builds');

SELECT is(pg_temp.idh_value($$SELECT obj_description(to_regclass('public.idh_meta'), 'pg_class')$$),
    pg_temp.idh_text('Many') || E'\n\n' || pg_temp.idh_text('About'),
    'the table comment is the plural label and the description as written');
SELECT is(pg_temp.idh_value($$
        SELECT col_description(a.attrelid, a.attnum) FROM pg_attribute a
         WHERE a.attrelid = to_regclass('public.idh_meta') AND a.attname = 'kind'$$),
    pg_temp.idh_text('Kind') || E' (enum)\n\n' || pg_temp.idh_text('Which') || E'\n\n'
        || (SELECT string_agg(val, ', ' ORDER BY n) FROM idh_texts),
    'the column comment is the title, the description and the enum values as written');

SELECT lives_ok(format('INSERT INTO idh_meta (label, kind) VALUES (%L, %L)', 'row ' || t.n, t.val),
                format('the enum CHECK accepts %s', t.val))
  FROM (SELECT * FROM idh_texts ORDER BY n) t;
SELECT is(pg_temp.idh_value($$SELECT string_agg(kind, ' | ' ORDER BY label) FROM idh_meta$$),
    (SELECT string_agg(val, ' | ' ORDER BY n) FROM idh_texts),
    'each value is stored as written');
-- The list holds the values, not their SQL or JSON spellings.
SELECT is(pg_temp.idh_refusal(format('INSERT INTO idh_meta (label, kind) VALUES (''other'', %L)', v.val)),
          '23514 idh_meta_kind_check',
          format('the enum CHECK refuses %s', v.what))
  FROM (VALUES (1, 'O''''Brien',   'the quote doubled'),
               (2, 'back\\slash', 'the backslash doubled'),
               (3, 'quoted',      'the double quotes left out')) AS v(n, val, what)
 ORDER BY v.n;

SELECT is(pg_temp.idh_value($$
        SELECT jsonb_build_array(s -> 'title', s -> 'table' -> 'singular_label', s -> 'table' -> 'plural_label',
                                 s -> 'description')::text
          FROM (SELECT public.get_schema('idh_meta')::jsonb AS s) x$$),
    jsonb_build_array(pg_temp.idh_text('One'), pg_temp.idh_text('One'), pg_temp.idh_text('Many'),
                      pg_temp.idh_text('About'))::text,
    'get_schema returns the labels and the description of the entity as written');
SELECT is(pg_temp.idh_value($$
        SELECT jsonb_build_array(p -> 'title', p -> 'description')::text
          FROM (SELECT public.get_schema('idh_meta')::jsonb -> 'properties' -> 'kind' AS p) x$$),
    jsonb_build_array(pg_temp.idh_text('Kind'), pg_temp.idh_text('Which'))::text,
    'get_schema returns the title and the description of the field as written');
-- An optional enum also lists its empty value.
SELECT is(pg_temp.idh_value($$
        SELECT (public.get_schema('idh_meta')::jsonb -> 'properties' -> 'kind' -> 'enum')::text$$),
    ((SELECT jsonb_agg(val ORDER BY n) FROM idh_texts) || '[""]'::jsonb)::text,
    'get_schema returns the enum values as written');

-- =====================================================
-- PART 6: a dollar-quote tag in a column default
-- =====================================================
-- The write routine of a has_a entity compares an attached record with the
-- defaults of the base's columns, so the default expressions of the base are
-- part of its generated source. A default is text an administrator chose: a
-- dollar-quote tag in it is three characters of a value, wherever the
-- generators put it and whatever tag they wrap their own bodies in. Each tag
-- the family generators and the label generator use has a family of its own:
-- a base idh_<name>_parties whose column code has the default x<tag>y, with
-- one record that holds another value, and the extension idh_<name>_vendors.
CREATE FUNCTION pg_temp.idh_dollar_base(p_base TEXT, p_prefix TEXT, p_default TEXT) RETURNS VOID LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                                 view_permission, edit_permission)
           VALUES (%L, 'Party', 'Parties', 1, 'typeid', %L, 'public:read', 'admin')$q$, p_base, p_prefix);
    EXECUTE format(
        $q$INSERT INTO fields (table_name, field_name, title, format, default_value)
           VALUES (%L, 'code', 'Code', 'text', %L)$q$, p_base, p_default);
    EXECUTE format($q$INSERT INTO public.%I (label, code) VALUES ('stored', 'own')$q$, p_base);
END $f$;

CREATE FUNCTION pg_temp.idh_dollar_extension(p_extension TEXT, p_base TEXT) RETURNS VOID LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE format(
        $q$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                                 view_permission, edit_permission)
           VALUES (%L, 'Vendor', 'Vendors', 1, 'has_a', %L, 'public:read', 'admin')$q$, p_extension, p_base);
    EXECUTE format(
        $q$INSERT INTO fields (table_name, field_name, title, format) VALUES (%L, 'terms', 'Terms', 'text')$q$,
        p_extension);
END $f$;

CREATE FUNCTION pg_temp.idh_dollar_family(p_name TEXT, p_tag TEXT) RETURNS SETOF TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_base      TEXT := format('idh_%s_parties', p_name);
    v_extension TEXT := format('idh_%s_vendors', p_name);
    v_default   TEXT := format('x%sy', p_tag);
BEGIN
    RETURN NEXT lives_ok(format('SELECT pg_temp.idh_dollar_base(%L, %L, %L)', v_base, 'idh' || p_name, v_default),
        format('%s: a base whose column defaults to %s builds', p_tag, v_default));
    RETURN NEXT lives_ok(format('SELECT pg_temp.idh_dollar_extension(%L, %L)', v_extension, v_base),
        format('%s: a has_a entity on that base builds', p_tag));
    -- No value for code: the view hands the routine the base column's default.
    RETURN NEXT lives_ok(format($q$INSERT INTO public.%I (label, terms) VALUES ('new', 'net30')$q$, v_extension),
        format('%s: a record is created through the extension', p_tag));
    RETURN NEXT is(pg_temp.idh_value(format($q$SELECT code FROM public.%I WHERE label = 'new'$q$, v_base)), v_default,
        format('%s: its base record holds the default', p_tag));
    -- An attach that names no value for code: the routine recognizes the
    -- default, which is where it compares with the expression, and takes the
    -- value of the base record.
    RETURN NEXT lives_ok(format(
        $q$INSERT INTO public.%I (id, terms) SELECT id, 'net60' FROM public.%I WHERE label = 'stored'$q$,
        v_extension, v_base),
        format('%s: an extension attaches to a base record that holds another value', p_tag));
    RETURN NEXT is(pg_temp.idh_value(format($q$SELECT code FROM public.%I WHERE terms = 'net60'$q$, v_extension)), 'own',
        format('%s: the attached record shows the stored value', p_tag));
END $f$;

SELECT pg_temp.idh_dollar_family('rw', '$RW$');
SELECT pg_temp.idh_dollar_family('vw', '$VW$');
SELECT pg_temp.idh_dollar_family('dispatch', '$DISPATCH$');
SELECT pg_temp.idh_dollar_family('body', '$body$');

SELECT * FROM finish();
ROLLBACK;
