-- Families: how an is_a / has_a family changes. Adding, changing or removing
-- a base (the root or a middle level) or a child - its entity row, its fields,
-- its records, its rules and permissions, the module that installs it - has to
-- reach every level: the views, the <entity>_ext columns, the generated write
-- routines, the triggers, the _label functions and get_schema. How a family is
-- built and written is pinned by 0435_test_entity_id_types.sql; this file pins
-- how it changes.
--
-- The file is one chain over one family, built once in a module of its own:
--
--   fcc_parties     typeid  (label, city)  view public:read  edit nwind:manage
--     fcc_orgs      is_a    (vat)          view nwind:view   edit nwind:manage
--       fcc_banks   is_a    (bic, tag)     view nwind:view   edit admin
--     fcc_persons   is_a    (birth)        view nwind:view   edit nwind:manage
--     fcc_vendors   has_a   (terms)        view nwind:view   edit nwind:manage
--
-- with one record per level - P1, O1, B1, R1 - and a vendor extension on B1,
-- so an is_a and a has_a entity share one base record. Every step starts from
-- the state the step before it verified, changes one thing and verifies the
-- result, which the next step builds on: a real family is changed over and
-- over too, and a change has to work on a family earlier changes shaped. The
-- steps that rename members come late, and the ones that take the family
-- apart last. When a step fails, the steps after it run on a state nobody
-- verified; the first failure is the finding. Two things no change of this
-- family can reach get small families of their own: a root and a child in two
-- modules, and a family keyed by pid instead of id.
--
-- banks.tag is computed as "T:" followed by the root's city. It follows a
-- change of city only when the bank's own write routine ran, which is what
-- shows that a write reached the record's own type.
--
-- user3 (admin) changes the dictionary. user2 holds nwind:view and
-- nwind:manage but not admin: it reads every level and writes every level but
-- banks. Entities outside the families are named fcx_. A refusal is asserted
-- with pg_temp.sqlstate_of, which rolls back whatever the statement did even
-- when it succeeds, or with throws_ok. Everything is rolled back.
--
--   1  fields of the root and of a middle level
--   2  a refused field and the DDL audit
--   3  the key column
--   4  the root's label
--   5  entity labels, a new subtype, prefixes, a record missing a part
--   6  rules, permissions and queues
--   7  an is_a and a has_a entity on one base record
--   8  a changed default and an attach
--   9  references from other entities
--   10 objects built on family views
--   11 the root's order column, and renames
--   12 taking the family apart; is_child; modules
--   13 a family keyed by pid

BEGIN;

SELECT plan(363);

-- =====================================================
-- Helpers
-- =====================================================
-- pg_temp functions take no EXECUTE grant: a function outside public and
-- common keeps the PUBLIC default, and every role may use the session's temp
-- schema, so they run as whichever user the test authenticated as.

-- Named values a later assertion compares with: record ids, snapshots, row
-- positions, audit log marks. Created by the connection's role and granted to
-- the request role, which writes most of them.
CREATE TEMP TABLE fc_marks (k TEXT PRIMARY KEY, v TEXT NOT NULL);
GRANT SELECT, INSERT, UPDATE, DELETE ON fc_marks TO semantius_user;

-- The standard family under the name prefix p and the TypeID prefix stem x,
-- in module p_module, with its records, whose ids are kept in fc_marks. p_key
-- names the root's key column, which every level inherits.
CREATE FUNCTION pg_temp.fc_build(p TEXT, x TEXT, p_module BIGINT, p_key TEXT DEFAULT 'id')
RETURNS VOID LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_column,
                              view_permission, edit_permission)
        VALUES (%L, 'Party', 'Parties', %s, 'typeid', %L, %L, 'public:read', 'nwind:manage')$q$,
        p || 'parties', p_module, x || 'pty', p_key);
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'city', 'City', 'text', 30)$q$,
        p || 'parties');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Organization', 'Organizations', %s, 'is_a', %L, %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'orgs', p_module, x || 'org', p || 'parties');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'vat', 'VAT', 'text', 30)$q$,
        p || 'orgs');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Bank', 'Banks', %s, 'is_a', %L, %L, 'nwind:view', 'admin')$q$,
        p || 'banks', p_module, x || 'bnk', p || 'orgs');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%1$L, 'bic', 'BIC', 'text', 30), (%1$L, 'tag', 'Tag', 'text', 40)$q$,
        p || 'banks');
    EXECUTE format($q$
        UPDATE entities
           SET computed_fields = '[{"name": "tag", "jsonlogic": {"cat": ["T:", {"var": "city"}]}}]'::jsonb
         WHERE table_name = %L$q$,
        p || 'banks');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Person', 'Persons', %s, 'is_a', %L, %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'persons', p_module, x || 'per', p || 'parties');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'birth', 'Birth', 'date', 30)$q$,
        p || 'persons');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Vendor', 'Vendors', %s, 'has_a', %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'vendors', p_module, p || 'parties');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'terms', 'Terms', 'text', 30)$q$,
        p || 'vendors');

    EXECUTE format($q$INSERT INTO public.%I (label, city) VALUES ('P1', 'Rome')$q$, p || 'parties');
    EXECUTE format($q$INSERT INTO public.%I (label, city, vat) VALUES ('O1', 'Oslo', 'NO1')$q$, p || 'orgs');
    EXECUTE format($q$INSERT INTO public.%I (label, city, vat, bic) VALUES ('B1', 'Bern', 'CH1', 'BIC1')$q$, p || 'banks');
    EXECUTE format($q$INSERT INTO public.%I (label, city, birth) VALUES ('R1', 'Riga', '2001-01-01')$q$, p || 'persons');
    EXECUTE format($q$INSERT INTO public.%1$I (%3$I, terms) SELECT %3$I, 'net30' FROM public.%2$I WHERE label = 'B1'$q$,
        p || 'vendors', p || 'parties', p_key);
    EXECUTE format($q$INSERT INTO fc_marks SELECT 'id ' || %L || label, %I::TEXT FROM public.%I
                       WHERE label IN ('P1', 'O1', 'B1', 'R1')$q$,
        p, p_key, p || 'parties');
END $fn$;

-- The id of record p_label of the family built under the prefix p.
CREATE FUNCTION pg_temp.fc_id(p TEXT, p_label TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT m.v FROM fc_marks m WHERE m.k = 'id ' || p || p_label;
$fn$;

-- The SQLSTATE a statement raises, '00000' when it succeeds, and the hint of
-- its error. The statement always ends in an error, a sentinel one when it
-- succeeded, so its subtransaction is rolled back and nothing it did remains.
CREATE FUNCTION pg_temp.outcome_of(p_sql TEXT, OUT o_state TEXT, OUT o_hint TEXT)
LANGUAGE plpgsql AS $fn$
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION 'the statement succeeded' USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS o_state = RETURNED_SQLSTATE, o_hint = PG_EXCEPTION_HINT;
    END;
    IF o_state = 'ZZ001' THEN
        o_state := '00000';
        o_hint := '';
    END IF;
    o_hint := coalesce(o_hint, '');
END $fn$;

CREATE FUNCTION pg_temp.sqlstate_of(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT (pg_temp.outcome_of(p_sql)).o_state;
$fn$;

CREATE FUNCTION pg_temp.hint_of(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT (pg_temp.outcome_of(p_sql)).o_hint;
$fn$;

-- The one value a query returns, as text, or 'ERROR <sqlstate>'.
CREATE FUNCTION pg_temp.value_of(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_value TEXT;
BEGIN
    EXECUTE p_sql INTO v_value;
    RETURN v_value;
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERROR ' || SQLSTATE;
END $fn$;

-- Runs a write, then returns the value p_read reads back: 'no row' when it
-- finds none, 'ERROR <sqlstate>' when either statement fails. A write that
-- succeeds is kept.
CREATE FUNCTION pg_temp.fc_write(p_write TEXT, p_read TEXT) RETURNS TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_value TEXT;
BEGIN
    EXECUTE p_write;
    EXECUTE p_read INTO v_value;
    RETURN coalesce(v_value, 'no row');
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERROR ' || SQLSTATE;
END $fn$;

-- The relations among p_rels that have the column, sorted and comma-separated.
CREATE FUNCTION pg_temp.fc_with_column(p_rels TEXT[], p_column TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT coalesce(string_agg(c.relname::TEXT, ', ' ORDER BY c.relname), '')
      FROM pg_class c
      JOIN pg_attribute a ON a.attrelid = c.oid
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relname::TEXT = ANY (p_rels)
       AND a.attname = p_column
       AND a.attnum > 0
       AND NOT a.attisdropped;
$fn$;

-- The columns of a relation, in order.
CREATE FUNCTION pg_temp.fc_cols(p_rel TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(a.attname::TEXT, ', ' ORDER BY a.attnum)
      FROM pg_attribute a
     WHERE a.attrelid = to_regclass(format('public.%I', p_rel))
       AND a.attnum > 0
       AND NOT a.attisdropped;
$fn$;

-- The arguments of a trigger, each followed by a comma; NULL when the
-- relation has no trigger of that name.
CREATE FUNCTION pg_temp.fc_args(p_rel TEXT, p_trigger TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT replace(encode(t.tgargs, 'escape'), E'\\000', ',')
      FROM pg_trigger t
     WHERE t.tgrelid = to_regclass(format('public.%I', p_rel))
       AND t.tgname = p_trigger;
$fn$;

-- entities.is_child of the named entities.
CREATE FUNCTION pg_temp.fc_is_child(p_names TEXT[]) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(e.table_name || '=' || e.is_child::TEXT, ', ' ORDER BY e.table_name COLLATE "C")
      FROM entities e
     WHERE e.table_name = ANY (p_names);
$fn$;

-- TRUE while the entity rows of p_names exist, the root table p_names[1]
-- exists, and so do the view and the part of every other name.
CREATE FUNCTION pg_temp.fc_intact(p_names TEXT[]) RETURNS BOOLEAN LANGUAGE sql AS $fn$
    SELECT (SELECT count(*) FROM entities e WHERE e.table_name = ANY (p_names)) = cardinality(p_names)
       AND to_regclass(format('public.%I', p_names[1])) IS NOT NULL
       AND (SELECT bool_and(to_regclass(format('public.%I', m)) IS NOT NULL
                            AND to_regclass(format('public.%I', m || '_ext')) IS NOT NULL)
              FROM unnest(p_names[2:]) AS m);
$fn$;

-- A fingerprint of everything the dictionary generates for a family: the
-- definitions of the views, the bodies of the write, rule, dispatch, label and
-- select_rule routines, and the definitions of the triggers on the root, the
-- views and the parts. Equal fingerprints mean nothing of it changed.
CREATE FUNCTION pg_temp.fc_snapshot(p_root TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    WITH members AS (
        SELECT d.table_name FROM dd_descendants(p_root) d
    )
    SELECT md5(concat_ws(' | ',
        (SELECT string_agg(m.table_name || ':'
                           || coalesce(pg_get_viewdef(to_regclass(format('public.%I', m.table_name))), '-'),
                           '; ' ORDER BY m.table_name COLLATE "C")
           FROM members m),
        (SELECT string_agg(p.oid::regprocedure::TEXT || ':' || md5(p.prosrc), '; '
                           ORDER BY p.oid::regprocedure::TEXT COLLATE "C")
           FROM pg_proc p
          WHERE p.proname = 'is_a_dispatch_' || p_root
             OR p.proname IN (SELECT pre || m.table_name
                                FROM members m
                               CROSS JOIN unnest(ARRAY['record_write_', 'view_write_', 'record_rules_', 'select_rule_']) AS pre)
             OR (p.proname LIKE '%\_label' AND p.pronargs = 1
                 AND p.proargtypes[0] IN (SELECT to_regtype(format('public.%I', m.table_name))::oid FROM members m))),
        (SELECT string_agg(c.relname || '.' || t.tgname || ':' || pg_get_triggerdef(t.oid), '; '
                           ORDER BY c.relname, t.tgname)
           FROM pg_trigger t
           JOIN pg_class c ON c.oid = t.tgrelid
          WHERE NOT t.tgisinternal
            AND c.relnamespace = 'public'::regnamespace
            AND (c.relname = p_root
                 OR c.relname::TEXT IN (SELECT m.table_name FROM members m)
                 OR c.relname::TEXT IN (SELECT m.table_name || '_ext' FROM members m)))));
$fn$;

-- The messages a queue holds about one table. Called as the owner: the
-- request roles have no access to the queue tables.
CREATE FUNCTION pg_temp.fc_messages(p_queue TEXT, p_table TEXT) RETURNS INTEGER LANGUAGE sql AS $fn$
    SELECT count(*)::INTEGER FROM pgmq.read(p_queue, 0, 1000) m WHERE m.message ->> 'table' = p_table;
$fn$;

-- The DDL audit rows logged between two marks, with the relation p_rel and
-- the column of a column-level command replaced by placeholders, so the log
-- of one entity's change compares with another's.
CREATE FUNCTION pg_temp.fc_ddl_log(p_from TEXT, p_to TEXT, p_rel TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT coalesce(string_agg(l.command_tag || ' '
                               || regexp_replace(replace(coalesce(l.object_identity, ''), p_rel, '<t>'),
                                                 E'<t>\\.[a-z0-9_]+', '<t>.<c>'),
                               ', ' ORDER BY l.id), '')
      FROM audit_ddl_logs l
     WHERE l.id > (SELECT m.v::BIGINT FROM fc_marks m WHERE m.k = p_from)
       AND l.id <= (SELECT m.v::BIGINT FROM fc_marks m WHERE m.k = p_to);
$fn$;

-- The checks after a change: seven assertions over the family whose root is
-- p_root, named for p_step, on the records of the family built under p_ids.
-- Run as an administrator; checks 3 and 4 write.
--   1. every view, part, write routine, view trigger, part guard, _label
--      function, the root's dispatch and its has_a guard exist
--   2. each view shows the key, the fields of every level from the root down
--      (dd_family_fields) and the audit fields
--   3. a write through each level is read back
--   4. a root field written through the root and through the middle level on
--      the bank record reaches the bank's computed tag: the dispatch ran
--   5. typeid_assign, pk_immutable and a_has_a_guard carry the arguments the
--      dictionary describes
--   6. no generated routine names p_old, the name a rename gave up
--   7. every relation of the family can be read
-- A routine that does not exist cannot pass check 6 unnoticed: check 1 has
-- already failed for it. Checks 3 and 4 leave city 'W-root' on P1, vat
-- 'W-org' on O1, bic 'W-bank', city 'D-org' and terms 'W-vendor' on B1 and
-- birth 2002-02-02 on R1.
CREATE FUNCTION pg_temp.fc_checks_on(p_step TEXT, p_root TEXT, p_org TEXT, p_bank TEXT, p_person TEXT,
                                     p_vendor TEXT, p_old TEXT, p_ids TEXT)
RETURNS SETOF TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_views TEXT[] := ARRAY[p_org, p_bank, p_person, p_vendor];
    v_key   TEXT;
    v_p1    TEXT := pg_temp.fc_id(p_ids, 'P1');
    v_o1    TEXT := pg_temp.fc_id(p_ids, 'O1');
    v_b1    TEXT := pg_temp.fc_id(p_ids, 'B1');
    v_r1    TEXT := pg_temp.fc_id(p_ids, 'R1');
    v_name  TEXT;
    v_rel   REGCLASS;
    v_out   TEXT;
    v_have  TEXT;
    v_want  TEXT;
    v_pat   TEXT;
BEGIN
    SELECT e.id_column INTO v_key FROM entities e WHERE e.table_name = p_root;
    v_key := coalesce(v_key, 'id');

    -- 1
    v_out := '';
    FOREACH v_name IN ARRAY v_views LOOP
        v_rel := to_regclass(format('public.%I', v_name));
        IF v_rel IS NULL OR (SELECT c.relkind FROM pg_class c WHERE c.oid = v_rel) <> 'v' THEN
            v_out := v_out || ' view ' || v_name;
        END IF;
        IF to_regclass(format('public.%I', v_name || '_ext')) IS NULL THEN
            v_out := v_out || ' table ' || v_name || '_ext';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_proc p
                        WHERE p.pronamespace = 'common'::regnamespace AND p.proname = 'record_write_' || v_name) THEN
            v_out := v_out || ' common.record_write_' || v_name;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_proc p
                        WHERE p.pronamespace = 'common'::regnamespace AND p.proname = 'view_write_' || v_name) THEN
            v_out := v_out || ' common.view_write_' || v_name;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = v_rel AND t.tgname = 'view_write') THEN
            v_out := v_out || ' trigger view_write on ' || v_name;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                        WHERE t.tgrelid = to_regclass(format('public.%I', v_name || '_ext'))
                          AND t.tgname = 'a_ext_write_guard') THEN
            v_out := v_out || ' trigger a_ext_write_guard on ' || v_name || '_ext';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_proc p
                        WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_label' AND p.pronargs = 1
                          AND p.proargtypes[0] = to_regtype(format('public.%I', v_name))::oid) THEN
            v_out := v_out || ' _label(' || v_name || ')';
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p
                    WHERE p.pronamespace = 'common'::regnamespace AND p.proname = 'is_a_dispatch_' || p_root)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger t
                       WHERE t.tgrelid = to_regclass(format('public.%I', p_root)) AND t.tgname = 'a_is_a_dispatch') THEN
        v_out := v_out || ' dispatch of ' || p_root;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                    WHERE t.tgrelid = to_regclass(format('public.%I', p_root)) AND t.tgname = 'a_has_a_guard') THEN
        v_out := v_out || ' trigger a_has_a_guard on ' || p_root;
    END IF;
    RETURN NEXT is(v_out, '',
        p_step || ': every view, part, write routine, trigger and label function of the family exists');

    -- 2
    v_out := '';
    FOREACH v_name IN ARRAY v_views LOOP
        SELECT string_agg(a.attname::TEXT, ',' ORDER BY a.attnum) INTO v_have
          FROM pg_attribute a
         WHERE a.attrelid = to_regclass(format('public.%I', v_name))
           AND a.attnum > 0 AND NOT a.attisdropped AND a.attname <> 'search_vector';
        SELECT string_agg(s.col, ',' ORDER BY s.n) INTO v_want
          FROM (SELECT v_key AS col, 0::BIGINT AS n
                UNION ALL
                SELECT f.field_name, f.ordinality
                  FROM dd_family_fields(v_name) WITH ORDINALITY AS f
                 WHERE coalesce(f.ctype, '') NOT IN ('id', 'audit')
                UNION ALL SELECT 'created_at', 1000000
                UNION ALL SELECT 'updated_at', 1000001) s;
        IF v_have IS DISTINCT FROM v_want THEN
            v_out := v_out || format(' %s has (%s), wants (%s)', v_name, coalesce(v_have, 'nothing'), v_want);
        END IF;
    END LOOP;
    RETURN NEXT is(v_out, '',
        p_step || ': every view shows the key, the fields of every level from the root down, then the audit fields');

    -- 3
    v_have := concat_ws(' ',
        'root:' || pg_temp.fc_write(
            format('UPDATE public.%I SET city = %L WHERE %I = %L', p_root, 'W-root', v_key, v_p1),
            format('SELECT city FROM public.%I WHERE %I = %L', p_root, v_key, v_p1)),
        'org:' || pg_temp.fc_write(
            format('UPDATE public.%I SET vat = %L WHERE %I = %L', p_org, 'W-org', v_key, v_o1),
            format('SELECT vat FROM public.%I WHERE %I = %L', p_org, v_key, v_o1)),
        'bank:' || pg_temp.fc_write(
            format('UPDATE public.%I SET bic = %L WHERE %I = %L', p_bank, 'W-bank', v_key, v_b1),
            format('SELECT bic FROM public.%I WHERE %I = %L', p_bank, v_key, v_b1)),
        'person:' || pg_temp.fc_write(
            format('UPDATE public.%I SET birth = %L WHERE %I = %L', p_person, '2002-02-02', v_key, v_r1),
            format('SELECT to_char(birth, ''YYYY-MM-DD'') FROM public.%I WHERE %I = %L', p_person, v_key, v_r1)),
        'vendor:' || pg_temp.fc_write(
            format('UPDATE public.%I SET terms = %L WHERE %I = %L', p_vendor, 'W-vendor', v_key, v_b1),
            format('SELECT terms FROM public.%I WHERE %I = %L', p_vendor, v_key, v_b1)));
    RETURN NEXT is(v_have, 'root:W-root org:W-org bank:W-bank person:2002-02-02 vendor:W-vendor',
        p_step || ': a write through each level is stored');

    -- 4
    v_have := 'root:' || pg_temp.fc_write(
                  format('UPDATE public.%I SET city = %L WHERE %I = %L', p_root, 'D-root', v_key, v_b1),
                  format('SELECT city || ''/'' || tag FROM public.%I WHERE %I = %L', p_bank, v_key, v_b1))
              || ' org:' || pg_temp.fc_write(
                  format('UPDATE public.%I SET city = %L WHERE %I = %L', p_org, 'D-org', v_key, v_b1),
                  format('SELECT city || ''/'' || tag FROM public.%I WHERE %I = %L', p_bank, v_key, v_b1));
    RETURN NEXT is(v_have, 'root:D-root/T:D-root org:D-org/T:D-org',
        p_step || ': a root field written through the root and through the middle level runs the bank''s own rules');

    -- 5
    v_out := '';
    v_have := pg_temp.fc_args(p_root, 'typeid_assign');
    SELECT v_key || ',' || e.id_prefix || ','
           || coalesce((SELECT string_agg(s.id_prefix || ',', '' ORDER BY s.id_prefix)
                          FROM dd_descendants(p_root) d
                          JOIN entities s ON s.table_name = d.table_name
                         WHERE s.id_type = 'is_a'), '')
      INTO v_want
      FROM entities e
     WHERE e.table_name = p_root;
    IF v_have IS DISTINCT FROM v_want THEN
        v_out := v_out || format(' typeid_assign(%s) wants (%s)', coalesce(v_have, 'missing'), v_want);
    END IF;
    FOREACH v_name IN ARRAY ARRAY[p_root, p_org || '_ext', p_bank || '_ext', p_person || '_ext', p_vendor || '_ext'] LOOP
        v_have := pg_temp.fc_args(v_name, 'pk_immutable');
        IF v_have IS DISTINCT FROM v_key || ',' THEN
            v_out := v_out || format(' pk_immutable on %s (%s)', v_name, coalesce(v_have, 'missing'));
        END IF;
    END LOOP;
    v_have := pg_temp.fc_args(p_root, 'a_has_a_guard');
    SELECT v_key || ',' || string_agg(e.table_name || ',', '' ORDER BY e.table_name) INTO v_want
      FROM entities e
     WHERE e.id_refentity = p_root AND e.id_type = 'has_a';
    IF v_have IS DISTINCT FROM v_want THEN
        v_out := v_out || format(' a_has_a_guard(%s) wants (%s)', coalesce(v_have, 'missing'), coalesce(v_want, 'none'));
    END IF;
    RETURN NEXT is(v_out, '',
        p_step || ': typeid_assign, pk_immutable and a_has_a_guard carry the key, the prefixes and the extensions');

    -- 6
    v_have := '';
    IF p_old <> '' THEN
        v_pat := '%' || replace(p_old, '_', '\_') || '%';
        SELECT coalesce(string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname), '')
          INTO v_have
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE ((n.nspname = 'common' AND (p.proname LIKE 'view\_write\_%' OR p.proname LIKE 'is\_a\_dispatch\_%'
                                           OR p.proname LIKE 'record\_write\_%'))
                OR (n.nspname = 'public' AND (p.proname LIKE '%\_label' OR p.proname LIKE 'select\_rule\_%')))
           AND (p.proname LIKE v_pat OR p.prosrc LIKE v_pat);
    END IF;
    RETURN NEXT is(v_have, '',
        p_step || ': no generated routine keeps a name the family gave up');

    -- 7
    v_out := '';
    FOREACH v_name IN ARRAY ARRAY[p_root] || v_views LOOP
        BEGIN
            EXECUTE format('SELECT 1 FROM public.%I LIMIT 0', v_name);
        EXCEPTION WHEN OTHERS THEN
            v_out := v_out || format(' %s (%s)', v_name, SQLSTATE);
        END;
    END LOOP;
    RETURN NEXT is(v_out, '',
        p_step || ': every relation of the family can be read');
END $fn$;

-- The checks on the family built under the prefix p, under its built names.
CREATE FUNCTION pg_temp.fc_checks(p_step TEXT, p TEXT) RETURNS SETOF TEXT LANGUAGE sql AS $fn$
    SELECT * FROM pg_temp.fc_checks_on(p_step, p || 'parties', p || 'orgs', p || 'banks', p || 'persons',
                                       p || 'vendors', '', p);
$fn$;

-- =====================================================
-- The family
-- =====================================================

SELECT authenticate_as('user3');
INSERT INTO modules (module_name) VALUES ('fcc_mod');
SELECT pg_temp.fc_build('fcc_', 'fcc', (SELECT id FROM modules WHERE module_name = 'fcc_mod'));

SELECT * FROM pg_temp.fc_checks('the family as built', 'fcc_');

-- =====================================================
-- 1. Fields of the root and of a middle level
-- =====================================================
-- A statement on fields ends in the family refresh: every view below the
-- changed level shows its columns and every write routine writes them.

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_parties', 'fcczone', 'Zone', 'text', 40);

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fcczone'),
    'fcc_banks, fcc_orgs, fcc_persons, fcc_vendors',
    'root field add: every view shows the new column');

SELECT is(pg_temp.fc_write($$UPDATE fcc_banks SET fcczone = 'north' WHERE label = 'B1'$$,
                           $$SELECT fcczone FROM fcc_parties WHERE label = 'B1'$$),
    'north',
    'root field add: the column is written through the grandchild''s view into the root');

SELECT * FROM pg_temp.fc_checks('after a root field add', 'fcc_');

UPDATE fields SET field_name = 'fccarea' WHERE table_name = 'fcc_parties' AND field_name = 'fcczone';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fcczone')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fccarea'),
    ' | fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors',
    'root field rename: the root and every view show the column under its new name only');

SELECT is(pg_temp.value_of($$SELECT fccarea FROM fcc_banks WHERE label = 'B1'$$), 'north',
    'root field rename: the value is kept');

SELECT * FROM pg_temp.fc_checks_on('after a root field rename',
    'fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors', 'fcczone', 'fcc_');

-- A default is set on the root table and copied to every view.
UPDATE fields SET default_value = 'Nowhere' WHERE table_name = 'fcc_parties' AND field_name = 'fccarea';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attrdef d
       JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       JOIN pg_class c ON c.oid = d.adrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')
        AND a.attname = 'fccarea'
        AND pg_get_expr(d.adbin, d.adrelid) LIKE '%Nowhere%'),
    'fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors',
    'root default change: the root table and every view carry the new default');

INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B2', 'Basel', 'CH2', 'BIC2');

SELECT is(pg_temp.value_of($$SELECT fccarea FROM fcc_parties WHERE label = 'B2'$$), 'Nowhere',
    'root default change: an insert through the grandchild that leaves the field out gets the default');

SELECT * FROM pg_temp.fc_checks('after a root default change', 'fcc_');

-- The title and description reach the column comment of every view.
UPDATE fields SET title = 'Area', description = 'Where it is'
 WHERE table_name = 'fcc_parties' AND field_name = 'fccarea';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')
        AND a.attname = 'fccarea'
        AND col_description(c.oid, a.attnum::INTEGER) = E'Area (text)\n\nWhere it is'),
    'fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors',
    'root title and description change: the root table and every view carry the new column comment');

SELECT * FROM pg_temp.fc_checks('after a root title and description change', 'fcc_');

DELETE FROM fields WHERE table_name = 'fcc_parties' AND field_name = 'fccarea';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fccarea'),
    '',
    'root field delete: the column is gone from the root and every view');

SELECT * FROM pg_temp.fc_checks('after a root field delete', 'fcc_');

-- A format change to another format of the same type is a comment change.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_parties', 'fccmail', 'Mail', 'text', 50);
UPDATE fields SET format = 'email' WHERE table_name = 'fcc_parties' AND field_name = 'fccmail';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')
        AND a.attname = 'fccmail'
        AND col_description(c.oid, a.attnum::INTEGER) = 'Mail (email)'),
    'fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors',
    'root format change of the same type: allowed, and every view''s column comment names the new format');

SELECT * FROM pg_temp.fc_checks('after a root format change of the same type', 'fcc_');

-- A format change to another type is refused before anything is rebuilt.
INSERT INTO fc_marks VALUES ('before int32', pg_temp.fc_snapshot('fcc_parties'));

SELECT throws_ok($$UPDATE fields SET format = 'int32' WHERE table_name = 'fcc_parties' AND field_name = 'fccmail'$$,
    '90223', NULL,
    'root format change of another type: refused');

SELECT is(pg_temp.fc_snapshot('fcc_parties'), (SELECT v FROM fc_marks WHERE k = 'before int32'),
    'root format change of another type: every view, routine and trigger of the family is as it was');

-- A root reference field: its <fk>_label is a function of every view.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fcx_owners', 'Owner', 'Owners', 1),
       ('fcx_owners2', 'Second Owner', 'Second Owners', 1);
INSERT INTO fcx_owners (id, label) VALUES (1, 'Ann');
INSERT INTO fcx_owners2 (id, label) VALUES (1, 'Zed');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_parties', 'owner_id', 'Owner', 'reference', 'fcx_owners', 'restrict', 60);
UPDATE fcc_banks SET owner_id = 1 WHERE label = 'B1';

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'owner_id_label' AND pronargs = 1
               AND proargtypes[0] = to_regtype('public.fcc_banks')::oid)
    AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.fcc_banks'::regclass AND attname = 'owner_id_label'),
    'root reference field: the grandchild''s view gets owner_id_label as a function, not a column');

SELECT is(pg_temp.value_of($$SELECT public.owner_id_label(b) FROM fcc_banks b WHERE b.label = 'B1'$$), 'Ann',
    'root reference field: the grandchild''s owner_id_label resolves the referenced record');

SELECT * FROM pg_temp.fc_checks('after a root reference field add', 'fcc_');

UPDATE fields SET reference_table = 'fcx_owners2' WHERE table_name = 'fcc_parties' AND field_name = 'owner_id';

SELECT is(pg_temp.value_of($$SELECT public.owner_id_label(b) FROM fcc_banks b WHERE b.label = 'B1'$$), 'Zed',
    'root reference field: a changed reference_table repoints the label function of every level');

SELECT * FROM pg_temp.fc_checks('after a root reference field is repointed', 'fcc_');

DELETE FROM fields WHERE table_name = 'fcc_parties' AND field_name = 'owner_id';

SELECT is(
    (SELECT count(*)::INTEGER FROM pg_proc
      WHERE proname = 'owner_id_label' AND pronargs = 1
        AND proargtypes[0] IN (SELECT to_regtype('public.' || n)::oid
                                 FROM unnest(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors']) AS n)),
    0,
    'root reference field delete: no level keeps its label function');

SELECT * FROM pg_temp.fc_checks('after a root reference field delete', 'fcc_');

-- Delete modes of root fields. A referential action runs inside a trigger,
-- where the dispatch leaves the write to the action, so it reaches the root
-- row only.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fcx_regions', 'Region', 'Regions', 1);
INSERT INTO fcx_regions (label) VALUES ('RA'), ('RB');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_parties', 'region_id', 'Region', 'reference', 'fcx_regions', 'cascade', 70);
UPDATE fcc_parties SET region_id = (SELECT id FROM fcx_regions WHERE label = 'RA') WHERE label = 'B2';
UPDATE fcc_parties SET region_id = (SELECT id FROM fcx_regions WHERE label = 'RB') WHERE label = 'B1';

-- The part's RESTRICT key refuses it: 23001 (restrict_violation) on
-- PostgreSQL 18, 23503 (foreign_key_violation) before it. The message is the
-- same on both.
SELECT throws_like($$DELETE FROM fcx_regions WHERE label = 'RA'$$,
    '%foreign key constraint "fcc\_orgs\_ext\_id\_fkey"%',
    'a cascading root reference cannot delete the root row of a subtype record from under its parts');

SELECT throws_ok($$DELETE FROM fcx_regions WHERE label = 'RB'$$,
    '90251', NULL,
    'a cascading root reference cannot delete a record that still has an extension');

UPDATE fields SET reference_delete_mode = 'clear' WHERE table_name = 'fcc_parties' AND field_name = 'region_id';
DELETE FROM fcx_regions WHERE label = 'RA';

SELECT is(pg_temp.value_of($$SELECT coalesce(region_id::TEXT, 'cleared') FROM fcc_banks WHERE label = 'B2'$$), 'cleared',
    'a clearing root reference clears the column of a subtype record whose referenced record is deleted');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_orgs', 'org_region_id', 'Organization Region', 'reference', 'fcx_regions', 'restrict', 50);

SELECT throws_ok(
    $$UPDATE fields SET reference_delete_mode = 'cascade' WHERE table_name = 'fcc_orgs' AND field_name = 'org_region_id'$$,
    '90249', NULL,
    'a reference field of a subtype cannot be changed to cascade');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_vendors', 'vendor_region_id', 'Vendor Region', 'reference', 'fcx_regions', 'cascade', 50);
UPDATE fcc_vendors SET vendor_region_id = (SELECT id FROM fcx_regions WHERE label = 'RB') WHERE label = 'B1';
DELETE FROM fcx_regions WHERE label = 'RB';

SELECT is(
    (SELECT count(*) FROM fcc_vendors WHERE label = 'B1')::TEXT || '/' || (SELECT count(*) FROM fcc_banks WHERE label = 'B1')::TEXT,
    '0/1',
    'a cascading reference of an extension only detaches the extension; the record stays');

INSERT INTO fcc_vendors (id, terms) SELECT id, 'net30' FROM fcc_parties WHERE label = 'B1';

-- A unique root field is unique across the records of every level.
INSERT INTO fields (table_name, field_name, title, format, field_order, unique_value)
VALUES ('fcc_parties', 'code', 'Code', 'text', 80, TRUE);
UPDATE fcc_banks SET code = 'C1' WHERE label = 'B1';

SELECT throws_ok($$INSERT INTO fcc_persons (label, code) VALUES ('R2', 'C1')$$,
    '23505', NULL,
    'a unique root field: a person cannot repeat a bank''s value');

-- Field names are unique along a chain of bases, on the rename path too.
SELECT throws_ok($$UPDATE fields SET field_name = 'bic' WHERE table_name = 'fcc_parties' AND field_name = 'code'$$,
    '90243', NULL,
    'a root field cannot be renamed to the name of a field of the grandchild');

SELECT throws_ok($$UPDATE fields SET field_name = 'code' WHERE table_name = 'fcc_banks' AND field_name = 'bic'$$,
    '90243', NULL,
    'a grandchild''s field cannot be renamed to the name of a root field');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_persons', 'pnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'org and bank columns', pg_temp.fc_cols('fcc_orgs') || ' | ' || pg_temp.fc_cols('fcc_banks');

SELECT lives_ok($$UPDATE fields SET field_name = 'bic' WHERE table_name = 'fcc_persons' AND field_name = 'pnote'$$,
    'a subtype may rename a field to a name its sibling''s branch uses: the two never share a record');

SELECT is(pg_temp.fc_cols('fcc_orgs') || ' | ' || pg_temp.fc_cols('fcc_banks'),
    (SELECT v FROM fc_marks WHERE k = 'org and bank columns'),
    'a sibling''s field change leaves the columns of the other branch as they were');

-- A middle-level field reaches the level below it, not the sibling branch or
-- the extension.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_orgs', 'fcconote', 'Organization Note', 'text', 60);

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fcconote'),
    'fcc_banks, fcc_orgs',
    'middle-level field add: the level and the one below it show it, the sibling branch and the extension do not');

SELECT * FROM pg_temp.fc_checks('after a middle-level field add', 'fcc_');

UPDATE fields SET field_name = 'fccomemo' WHERE table_name = 'fcc_orgs' AND field_name = 'fcconote';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fcconote')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fccomemo'),
    ' | fcc_banks, fcc_orgs',
    'middle-level field rename: the level and the one below it show the new name only');

SELECT * FROM pg_temp.fc_checks_on('after a middle-level field rename',
    'fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors', 'fcconote', 'fcc_');

DELETE FROM fields WHERE table_name = 'fcc_orgs' AND field_name = 'fccomemo';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_orgs_ext', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fccomemo'),
    '',
    'middle-level field delete: gone from its part and from every view');

SELECT * FROM pg_temp.fc_checks('after a middle-level field delete', 'fcc_');

-- Searchable on the root.
UPDATE fields SET searchable = FALSE WHERE table_name = 'fcc_parties' AND field_name = 'label';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'search_vector'),
    '',
    'searchable: with no searchable field in the family, no level has a search_vector');

UPDATE fields SET searchable = TRUE WHERE table_name = 'fcc_parties' AND field_name = 'city';

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'search_vector')
          || ' / ' || (SELECT string_agg(table_name, ', ' ORDER BY table_name COLLATE "C") FROM entities
                        WHERE table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')
                          AND searchable),
    'fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors / fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors',
    'searchable: a searchable root field makes every level searchable and gives every view a search_vector');

UPDATE fcc_parties SET city = 'Zurichfccone' WHERE label = 'B1';

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fcc_banks WHERE search_vector @@ to_tsquery('simple', 'zurichfccone')$$),
    '1',
    'searchable: a search through the grandchild''s view finds text stored in the root');

SELECT * FROM pg_temp.fc_checks('after a searchable change on the root', 'fcc_');

-- get_schema of the grandchild describes the root field as it is now.
UPDATE fields SET title = 'Town' WHERE table_name = 'fcc_parties' AND field_name = 'city';

SELECT is(
    ((public.get_schema('fcc_banks')::jsonb) #>> '{properties,city,title}')
    || ' from ' || ((public.get_schema('fcc_banks')::jsonb) #>> '{properties,city,inherited_from}'),
    'Town from fcc_parties',
    'get_schema of the grandchild shows a root field''s new title, inherited from the root');

-- =====================================================
-- 2. A refused field and the DDL audit
-- =====================================================
-- A refusal is raised before the family is rebuilt, so the family is left
-- exactly as it was. A change that is carried out logs its own DDL, not the
-- rebuild that follows from it.

INSERT INTO fc_marks VALUES ('before clash', pg_temp.fc_snapshot('fcc_parties'));

SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                   VALUES ('fcc_parties', 'bic', 'BIC', 'text', 90)$$,
    '90243', NULL,
    'a root field whose name a subtype uses is refused');

SELECT is(pg_temp.fc_snapshot('fcc_parties'), (SELECT v FROM fc_marks WHERE k = 'before clash'),
    'the refused field leaves every view, routine and trigger of the family as it was');

INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fcx_plain', 'Plain', 'Plains', 1);
INSERT INTO fc_marks SELECT 'audit start', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fcx_plain', 'pnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'audit plain', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fcc_parties', 'rnote', 'Note', 'text', 90);
INSERT INTO fc_marks SELECT 'audit root', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fcc_orgs', 'onote', 'Note', 'text', 90);
INSERT INTO fc_marks SELECT 'audit org', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fcc_banks', 'bnote', 'Note', 'text', 90);
INSERT INTO fc_marks SELECT 'audit bank', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;

SELECT is(pg_temp.fc_ddl_log('audit plain', 'audit root', 'fcc_parties'),
    pg_temp.fc_ddl_log('audit start', 'audit plain', 'fcx_plain'),
    'a root field add logs its own DDL only, not the rebuild of the views and routines of three levels');

SELECT is(pg_temp.fc_ddl_log('audit root', 'audit org', 'fcc_orgs_ext'),
    pg_temp.fc_ddl_log('audit start', 'audit plain', 'fcx_plain'),
    'a middle-level field add logs its own DDL only');

SELECT is(pg_temp.fc_ddl_log('audit org', 'audit bank', 'fcc_banks_ext'),
    pg_temp.fc_ddl_log('audit start', 'audit plain', 'fcx_plain'),
    'a grandchild field add logs its own DDL only');

-- =====================================================
-- 3. The key column
-- =====================================================
-- id_column names the physical key. Changing the row runs no DDL, so a
-- changed id_column would describe a column that does not exist; it is set
-- when an entity is created, for every key type.

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fcc_parties'$$), '90253',
    'id_column cannot change on a family root');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fcc_orgs'$$), '90253',
    'id_column cannot change on an is_a entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fcc_vendors'$$), '90253',
    'id_column cannot change on a has_a entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fcx_plain'$$), '90253',
    'id_column cannot change on a plain entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'id' WHERE table_name = 'fcc_parties'$$), '00000',
    'an update that writes the same id_column back passes');

SELECT is(
    (SELECT string_agg(e.table_name || '=' || e.id_column || '/' || f.field_name || '/' || a.attname,
                       ', ' ORDER BY e.table_name COLLATE "C")
       FROM entities e
       JOIN fields f ON f.table_name = e.table_name AND f.ctype = 'id'
       JOIN pg_constraint k ON k.conrelid = to_regclass(format('public.%I', dd_relation(e.table_name))) AND k.contype = 'p'
       JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
      WHERE e.table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_vendors', 'fcx_plain')),
    'fcc_orgs=id/id/id, fcc_parties=id/id/id, fcc_vendors=id/id/id, fcx_plain=id/id/id',
    'id_column, the id field row and the physical key are unchanged');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fcc_parties', 'fccextra', 'Extra', 'text', 100)$$,
    'a root field add still works');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fcx_plain', 'fccextra', 'Extra', 'text', 50)$$,
    'a field add on the plain entity still works');

-- =====================================================
-- 4. The root's label
-- =====================================================
-- Every level's records are the root's records, so every level's label column
-- is the root's (90242 holds a derived entity to it). A change of the root's
-- label column, by a rename of its field or directly, has to reach every
-- level, or every later write to a derived entity's row is refused.

UPDATE fields SET field_name = 'fcctitle' WHERE table_name = 'fcc_parties' AND field_name = 'label';

SELECT is(
    (SELECT string_agg(table_name || '=' || label_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')),
    'fcc_banks=fcctitle, fcc_orgs=fcctitle, fcc_parties=fcctitle, fcc_persons=fcctitle, fcc_vendors=fcctitle',
    'label field rename: the label column of every level follows the root''s');

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fcctitle')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'label'),
    'fcc_banks, fcc_orgs, fcc_parties, fcc_persons, fcc_vendors | ',
    'label field rename: the root and every view show the column under its new name only');

SELECT is(pg_temp.fc_write($$UPDATE fcc_banks SET fcctitle = 'B1-renamed' WHERE fcctitle = 'B1'$$,
                           $$SELECT fcctitle FROM fcc_parties WHERE fcctitle = 'B1-renamed'$$),
    'B1-renamed',
    'label field rename: the label is written through the grandchild');

SELECT is(pg_temp.fc_write($$UPDATE fcc_parties SET fcctitle = 'B1' WHERE fcctitle = 'B1-renamed'$$,
                           $$SELECT fcctitle FROM fcc_banks WHERE fcctitle = 'B1'$$),
    'B1',
    'label field rename: and through the root');

SELECT * FROM pg_temp.fc_checks('after a rename of the root''s label field', 'fcc_');

UPDATE fields SET field_name = 'label' WHERE table_name = 'fcc_parties' AND field_name = 'fcctitle';

SELECT is(
    (SELECT count(*)::INTEGER FROM entities
      WHERE table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')
        AND label_column <> 'label')
    + (SELECT count(*)::INTEGER FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'fcc\_%'
          AND a.attname = 'fcctitle' AND NOT a.attisdropped),
    0,
    'label field renamed back: no label column and no column keeps the intermediate name');

SELECT * FROM pg_temp.fc_checks_on('after the label field is renamed back',
    'fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors', 'fcctitle', 'fcc_');

-- A derived entity's own label settings stay its root's.
SELECT throws_ok($$UPDATE entities SET label_column = 'vat' WHERE table_name = 'fcc_orgs'$$,
    '90242', NULL,
    'a child''s own label_column change is refused');

SELECT throws_ok($$UPDATE entities SET label_parent = 'vat' WHERE table_name = 'fcc_orgs'$$,
    '90242', NULL,
    'a child''s own label_parent change is refused');

SELECT throws_ok($$UPDATE entities SET label_column = 'bic' WHERE table_name = 'fcc_banks'$$,
    '90242', NULL,
    'a grandchild''s own label_column change is refused');

SELECT throws_ok($$UPDATE entities SET label_parent = 'bic' WHERE table_name = 'fcc_banks'$$,
    '90242', NULL,
    'a grandchild''s own label_parent change is refused');

-- The root's identity spine composes into every level's label.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fcx_units', 'Unit', 'Units', 1);
INSERT INTO fcx_units (label) VALUES ('U1');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_parties', 'unit_id', 'Unit', 'reference', 'fcx_units', 'clear', 110);
UPDATE fcc_parties SET unit_id = (SELECT id FROM fcx_units WHERE label = 'U1') WHERE label = 'B1';
UPDATE entities SET label_parent = 'unit_id' WHERE table_name = 'fcc_parties';

SELECT is(pg_temp.value_of($$SELECT public._label(b) FROM fcc_banks b WHERE b.label = 'B1'$$), 'U1 › B1',
    'a label_parent on the root composes the grandchild''s label');

SELECT is(pg_temp.value_of($$SELECT public._label(v) FROM fcc_vendors v WHERE v.label = 'B1'$$), 'U1 › B1',
    'a label_parent on the root composes the extension''s label');

UPDATE entities SET label_parent = '' WHERE table_name = 'fcc_parties';

-- A direct label_column change on the root. From here on the family is
-- labeled by city.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fcx_notes', 'Note', 'Notes', 1),
       ('fcx_memos', 'Memo', 'Memos', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcx_notes', 'bank_id', 'Bank', 'reference', 'fcc_banks', 'cascade', 30),
       ('fcx_memos', 'bank_id', 'Bank', 'reference', 'fcc_banks', 'clear', 30);
INSERT INTO fcx_notes (label, bank_id) SELECT 'N1', id FROM fcc_parties WHERE label = 'B1';
INSERT INTO fcx_memos (label, bank_id) SELECT 'M1', id FROM fcc_parties WHERE label = 'B1';
UPDATE fcc_parties SET city = 'Basel' WHERE label = 'B1';

UPDATE entities SET label_column = 'city' WHERE table_name = 'fcc_parties';

SELECT is(
    (SELECT string_agg(table_name || '=' || label_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')),
    'fcc_banks=city, fcc_orgs=city, fcc_parties=city, fcc_persons=city, fcc_vendors=city',
    'a direct label_column change on the root reaches every level');

SELECT is(pg_temp.value_of($$SELECT public._label(b) FROM fcc_banks b WHERE b.label = 'B1'$$), 'Basel',
    'after a direct label_column change on the root, the grandchild''s _label returns the new label column''s value');

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fcx_notes n WHERE n.label = 'N1'$$), 'Basel',
    'after a direct label_column change on the root, the label function of a plain entity referencing the grandchild returns the new label column''s value');

SELECT is((public.get_schema('fcc_banks')::jsonb) #>> '{table,label_column}', 'city',
    'get_schema of the grandchild names the new label column');

SELECT is((public.get_schema('fcx_notes')::jsonb) #>> '{properties,bank_id,reference_table_label_column}', 'city',
    'get_schema of the referencing entity names it as the referenced label column');

SELECT lives_ok($$UPDATE fields SET searchable = TRUE WHERE table_name = 'fcc_parties' AND field_name = 'label'$$,
    'after the change, a searchable change on the root goes through');

SELECT lives_ok($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
                  VALUES ('fcc_trusts', 'Trust', 'Trusts', 1, 'is_a', 'fcctru', 'fcc_parties')$$,
    'after the change, a new child of the root can be created');

SELECT is((SELECT label_column FROM entities WHERE table_name = 'fcc_trusts'), 'city',
    'the new child takes the root''s new label column');

DELETE FROM entities WHERE table_name = 'fcc_trusts';

-- =====================================================
-- 5. Entity labels, a new subtype, prefixes, a record missing a part
-- =====================================================

-- The root's labels are its own.
UPDATE entities SET singular_label = 'Counterparty', plural_label = 'Counterparties', description = 'Anyone we deal with'
 WHERE table_name = 'fcc_parties';

SELECT is(obj_description('public.fcc_parties'::regclass, 'pg_class'), E'Counterparties\n\nAnyone we deal with',
    'root labels: the root table''s comment follows');

SELECT is(((public.get_schema('fcc_parties')::jsonb) ->> 'title') || ' / ' || ((public.get_schema('fcc_parties')::jsonb) ->> 'description'),
    'Counterparty / Anyone we deal with',
    'root labels: so does the root''s get_schema');

SELECT is(
    (SELECT string_agg(c.relname || '=' || coalesce(obj_description(c.oid, 'pg_class'), ''), ', ' ORDER BY c.relname)
       FROM pg_class c
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')),
    'fcc_banks=Banks, fcc_orgs=Organizations, fcc_persons=Persons, fcc_vendors=Vendors',
    'root labels: every view keeps its own comment');

SELECT is(
    (SELECT string_agg(public.get_schema(n)::jsonb ->> 'title', ', ' ORDER BY o)
       FROM unnest(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors']) WITH ORDINALITY AS u(n, o)),
    'Organization, Bank, Person, Vendor',
    'root labels: every level''s get_schema keeps its own title');

UPDATE entities SET plural_label = 'Bank Branches', description = 'Branches that hold accounts'
 WHERE table_name = 'fcc_banks';

SELECT is(obj_description('public.fcc_banks'::regclass, 'pg_class'), E'Bank Branches\n\nBranches that hold accounts',
    'a child''s own labels reach its view''s comment');

-- A new subtype under a middle level that has records and a child.
INSERT INTO fc_marks
SELECT 'orgs before insurers',
       string_agg(label || ':' || common.typeid_prefix(id) || ':' || vat, ', ' ORDER BY label COLLATE "C")
  FROM fcc_orgs;
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('fcc_insurers', 'Insurer', 'Insurers', 1, 'is_a', 'fccins', 'fcc_orgs', 'nwind:view', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_insurers', 'policy', 'Policy', 'text', 30),
       ('fcc_insurers', 'itag', 'Insurer Tag', 'text', 40);
UPDATE entities SET computed_fields = '[{"name": "itag", "jsonlogic": {"cat": ["I:", {"var": "city"}]}}]'::jsonb
 WHERE table_name = 'fcc_insurers';

SELECT ok(pg_temp.fc_args('fcc_parties', 'typeid_assign') LIKE '%,fccins,%',
    'new subtype under a middle level: the root''s typeid_assign accepts its prefix');

SELECT lives_ok($$INSERT INTO fcc_insurers (label, city, vat, policy) VALUES ('I1', 'Ivrea', 'IT9', 'POL1')$$,
    'new subtype under a middle level: records are created through it');

SELECT is(pg_temp.fc_write($$UPDATE fcc_parties SET city = 'Imola' WHERE label = 'I1'$$,
                           $$SELECT itag FROM fcc_insurers WHERE label = 'I1'$$),
    'I:Imola',
    'new subtype under a middle level: the root''s dispatch routes to it');

SELECT is(pg_temp.fc_write($$UPDATE fcc_orgs SET city = 'Ischia' WHERE label = 'I1'$$,
                           $$SELECT itag FROM fcc_insurers WHERE label = 'I1'$$),
    'I:Ischia',
    'new subtype under a middle level: so does the middle level''s view');

SELECT is(
    (SELECT string_agg(label || ':' || common.typeid_prefix(id) || ':' || vat, ', ' ORDER BY label COLLATE "C")
       FROM fcc_orgs WHERE label <> 'I1'),
    (SELECT v FROM fc_marks WHERE k = 'orgs before insurers'),
    'new subtype under a middle level: the records already there are untouched');

SELECT * FROM pg_temp.fc_checks('after a new subtype under a middle level', 'fcc_');

DELETE FROM fcc_insurers WHERE label = 'I1';
DELETE FROM entities WHERE table_name = 'fcc_insurers';

-- A root prefix change after a has_a entity exists: the extension's write
-- routine mints and checks the root's ids. The root's rows keep the former
-- prefix, which is therefore not free for a new subtype: those rows would be
-- taken for records of that subtype.
INSERT INTO fcc_parties (label, city) VALUES ('P9', 'Pisa');
UPDATE entities SET id_prefix = 'fccptynew' WHERE table_name = 'fcc_parties';
INSERT INTO fcc_vendors (label, terms) VALUES ('S2', 'net60');

SELECT is((SELECT common.typeid_prefix(id) FROM fcc_parties WHERE label = 'S2'), 'fccptynew',
    'root prefix change: a base record created through the extension takes the new prefix');

SELECT throws_ok($$INSERT INTO fcc_vendors (id, label) VALUES ('fccpty_01h455vb4pex5vsknk084sn02q', 'S3')$$,
    '90237', NULL,
    'root prefix change: an id with the former prefix is refused');

SELECT is(pg_temp.sqlstate_of(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
      VALUES ('fcc_clubs', 'Club', 'Clubs', 1, 'is_a', 'fccpty', 'fcc_parties')$$),
    '90254',
    'a new subtype cannot take a prefix that rows of its root still carry');

SELECT is(pg_temp.fc_write($$UPDATE fcc_parties SET city = 'Reached' WHERE label = 'P9'$$,
                           $$SELECT city FROM fcc_parties WHERE label = 'P9'$$),
    'Reached',
    'the root''s rows under its former prefix are still updated through the root');

SELECT lives_ok($$DELETE FROM fcc_parties WHERE label = 'P9'$$,
    'the root''s rows under its former prefix are still deleted through the root');

SELECT is((SELECT count(*)::INTEGER FROM fcc_parties WHERE label = 'P9'), 0,
    'the delete removed the row');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fcx_misc', 'Misc', 'Miscs', 1, 'typeid', 'fccfree');
UPDATE entities SET id_prefix = 'fccfreetwo' WHERE table_name = 'fcx_misc';

SELECT lives_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
      VALUES ('fcc_clubs', 'Club', 'Clubs', 1, 'is_a', 'fccfree', 'fcc_parties')$$,
    'a released prefix that no row of the root carries can be taken by a new subtype');

DELETE FROM entities WHERE table_name = 'fcc_clubs';

-- A root row whose id names a subtype that has no part for it. Only the owner
-- can make one, by writing a part table past its guard; the part is put back
-- afterwards.
INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B5', 'Bonn', 'DE5', 'BIC5');

RESET ROLE;
ALTER TABLE public.fcc_banks_ext DISABLE TRIGGER a_ext_write_guard;
CREATE TEMP TABLE fc_saved_part AS
SELECT * FROM public.fcc_banks_ext WHERE id = (SELECT id FROM public.fcc_parties WHERE label = 'B5');
DELETE FROM public.fcc_banks_ext WHERE id = (SELECT id FROM fc_saved_part);
ALTER TABLE public.fcc_banks_ext ENABLE TRIGGER a_ext_write_guard;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$UPDATE fcc_parties SET city = 'Nowhere' WHERE label = 'B5'$$), '90255',
    'an update through the root of a record whose subtype part is missing is refused, not skipped');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM fcc_parties WHERE label = 'B5'$$), '90255',
    'a delete through the root of a record whose subtype part is missing is refused, not skipped');

RESET ROLE;
ALTER TABLE public.fcc_banks_ext DISABLE TRIGGER a_ext_write_guard;
INSERT INTO public.fcc_banks_ext SELECT * FROM fc_saved_part;
ALTER TABLE public.fcc_banks_ext ENABLE TRIGGER a_ext_write_guard;
SELECT authenticate_as('user3');

-- A subtype record the caller cannot read is skipped as before.
UPDATE fcc_parties SET city = 'Bern' WHERE label = 'B1';
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'fcc_banks';
SELECT authenticate_as('user2');

SELECT lives_ok($$UPDATE fcc_parties SET city = 'Ulm' WHERE label = 'B1'$$,
    'an update through the root of a subtype record the caller cannot read raises nothing');

SELECT authenticate_as('user3');

SELECT is((SELECT city FROM fcc_parties WHERE label = 'B1'), 'Bern',
    'the record the caller cannot read is skipped');

SELECT is(pg_temp.fc_write($$UPDATE fcc_parties SET city = 'Bremen' WHERE label = 'B1'$$,
                           $$SELECT city FROM fcc_banks WHERE label = 'B1'$$),
    'Bremen',
    'an administrator updates it');

UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'fcc_banks';

-- =====================================================
-- 6. Rules, permissions and queues
-- =====================================================
-- A level's rules and permissions apply to every record stored in it, so they
-- reach the levels below it and the writes carried down from the root.

UPDATE entities
   SET validation_rules = '[{"code": "99501", "message": "an organization cannot be in Nowhere",
                             "jsonlogic": {"!=": [{"var": "city"}, "Nowhere"]}}]'::jsonb
 WHERE table_name = 'fcc_orgs';

SELECT throws_ok($$UPDATE fcc_banks SET city = 'Nowhere' WHERE label = 'B1'$$,
    '99501', NULL,
    'a rule added to a middle level is enforced through the level below it');

SELECT throws_ok($$UPDATE fcc_parties SET city = 'Nowhere' WHERE label = 'B1'$$,
    '99501', NULL,
    'a rule added to a middle level is enforced through the root');

SELECT lives_ok($$UPDATE fcc_parties SET city = 'Nowhere' WHERE label = 'P1'$$,
    'a rule of a middle level does not apply to a record of the root''s own type');

UPDATE entities SET validation_rules = '[]'::jsonb WHERE table_name = 'fcc_orgs';

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'record_rules_fcc_orgs'),
    'clearing a middle level''s rules drops its rule routine');

SELECT lives_ok($$UPDATE fcc_banks SET city = 'Nowhere' WHERE label = 'B1'$$,
    'with the rules cleared, a write through the level below still works');

SELECT lives_ok($$UPDATE fcc_parties SET city = 'Bern' WHERE label = 'B1'$$,
    'with the rules cleared, a write through the root still works');

-- A middle level's view permission gates the levels below it.
INSERT INTO fc_marks SELECT 'banks', count(*)::TEXT FROM fcc_banks;
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'fcc_orgs';
SELECT authenticate_as('user2');

SELECT is((SELECT count(*)::INTEGER FROM fcc_banks), 0,
    'a middle level readable by administrators only hides the level below it from others');

SELECT throws_ok($$SELECT public.get_schema('fcc_banks')$$,
    '42P01', NULL,
    'a middle level readable by administrators only hides the schema of the level below it from others');

SELECT authenticate_as('user3');

SELECT is((SELECT count(*)::TEXT FROM fcc_banks), (SELECT v FROM fc_marks WHERE k = 'banks'),
    'an administrator still reads it');

SELECT lives_ok($$SELECT public.get_schema('fcc_banks')$$,
    'an administrator still reads its schema');

UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'fcc_orgs';

-- A select_rule on the root filters every view and the writes through the
-- root.
UPDATE fcc_parties SET city = 'Hidden' WHERE label = 'B1';
UPDATE entities
   SET select_rule = '{"or": [{"has_permission": "admin"}, {"!=": [{"var": "city"}, "Hidden"]}]}'::jsonb
 WHERE table_name = 'fcc_parties';
SELECT authenticate_as('user2');

SELECT is(
    (SELECT count(*)::INTEGER FROM fcc_orgs WHERE label = 'B1')
    + (SELECT count(*)::INTEGER FROM fcc_banks WHERE label = 'B1')
    + (SELECT count(*)::INTEGER FROM fcc_vendors WHERE label = 'B1'),
    0,
    'a select_rule on the root hides the record in every view of the family');

UPDATE fcc_parties SET city = 'Seen' WHERE label = 'B1';
SELECT authenticate_as('user3');

SELECT is((SELECT city FROM fcc_parties WHERE label = 'B1'), 'Hidden',
    'a select_rule on the root keeps a write through the root off the record');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'fcc_parties';

-- A queue mapped on the root reports changes to root rows: a subtype record's
-- root row is created, changed or deleted with it, its other parts are not.
INSERT INTO queues (queue_name) VALUES ('fcxq_events');
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'party change', 'fcc_parties', 'change' FROM queues WHERE queue_name = 'fcxq_events';

INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B7', 'Brno', 'CZ7', 'BIC7');

RESET ROLE;
SELECT is(pg_temp.fc_messages('fcxq_events', 'fcc_parties'), 1,
    'a queue on the root: creating a subtype record sends one message');
SELECT authenticate_as('user3');

UPDATE fcc_banks SET bic = 'BIC8' WHERE label = 'B7';

RESET ROLE;
SELECT is(pg_temp.fc_messages('fcxq_events', 'fcc_parties'), 1,
    'a queue on the root: an update of subtype fields only sends none');
SELECT authenticate_as('user3');

UPDATE fcc_banks SET city = 'Brugge' WHERE label = 'B7';

RESET ROLE;
SELECT is(pg_temp.fc_messages('fcxq_events', 'fcc_parties'), 2,
    'a queue on the root: an update of a root field sends one');
SELECT authenticate_as('user3');

DELETE FROM fcc_banks WHERE label = 'B7';

RESET ROLE;
SELECT is(pg_temp.fc_messages('fcxq_events', 'fcc_parties'), 3,
    'a queue on the root: deleting the subtype record sends one');
SELECT authenticate_as('user3');

SELECT throws_ok(
    $$INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
      SELECT id, 'bank change', 'fcc_banks', 'change' FROM queues WHERE queue_name = 'fcxq_events'$$,
    '90249', NULL,
    'a queue cannot be mapped on the subtype itself');

DELETE FROM queue_table_events WHERE table_name = 'fcc_parties';

-- =====================================================
-- 7. An is_a and a has_a entity on one base record
-- =====================================================
-- B1 is a bank and has a vendor extension. A root field written through the
-- extension is a change of the bank record, so the rules and permissions of
-- every level of the bank apply to it.

UPDATE fcc_parties SET city = 'Bern' WHERE label = 'B1';
UPDATE fcc_vendors SET terms = 'net30' WHERE label = 'B1';

SELECT is((SELECT label || '/' || city || '/' || terms FROM fcc_vendors WHERE label = 'B1'), 'B1/Bern/net30',
    'the extension of a subtype record shows the root''s fields');

SELECT throws_ok($$INSERT INTO fcc_vendors (id, city, terms) SELECT id, 'Elsewhere', 'net5' FROM fcc_parties WHERE label = 'O1'$$,
    '90246', NULL,
    'an attach that brings a root value other than the stored one is refused');

UPDATE fcc_parties SET city = 'Basel' WHERE label = 'B1';

SELECT is((SELECT v.city || '/' || b.city || '/' || b.tag FROM fcc_vendors v JOIN fcc_banks b ON b.id = v.id WHERE v.label = 'B1'),
    'Basel/Basel/T:Basel',
    'a root field change reaches the extension and the subtype in the same statement');

UPDATE fcc_vendors SET city = 'Vaduz' WHERE label = 'B1';

SELECT is((SELECT city || '/' || tag FROM fcc_banks WHERE label = 'B1'), 'Vaduz/T:Vaduz',
    'a root field written through the extension runs the rules of the record''s own type');

UPDATE entities
   SET validation_rules = '[{"code": "99601", "message": "an organization cannot be in Forbidden",
                             "jsonlogic": {"!=": [{"var": "city"}, "Forbidden"]}}]'::jsonb
 WHERE table_name = 'fcc_orgs';

SELECT is(pg_temp.sqlstate_of($$UPDATE fcc_vendors SET city = 'Forbidden' WHERE label = 'B1'$$), '99601',
    'a root field written through the extension runs the rules of the levels in between');

SELECT authenticate_as('user2');

SELECT lives_ok($$UPDATE fcc_vendors SET city = 'Ulm', terms = 'net1' WHERE label = 'B1'$$,
    'a caller who may write the extension and the root but not the subtype: the update raises nothing');

SELECT authenticate_as('user3');

SELECT is((SELECT p.city || '/' || v.terms FROM fcc_parties p JOIN fcc_vendors v ON v.id = p.id WHERE p.label = 'B1'),
    'Vaduz/net30',
    'that caller''s update skips the record: neither the root nor the extension changes');

SELECT is(pg_temp.fc_write($$UPDATE fcc_vendors SET city = 'Uppsala', terms = 'net2' WHERE label = 'B1'$$,
                           $$SELECT p.city || '/' || v.terms FROM fcc_parties p JOIN fcc_vendors v ON v.id = p.id WHERE p.label = 'B1'$$),
    'Uppsala/net2',
    'an administrator''s same update is written');

INSERT INTO fcc_vendors (id, terms) SELECT id, 'net10' FROM fcc_parties WHERE label = 'P1';

SELECT is(pg_temp.fc_write($$UPDATE fcc_vendors SET city = 'Pisa' WHERE label = 'P1'$$,
                           $$SELECT city FROM fcc_parties WHERE label = 'P1'$$),
    'Pisa',
    'the extension of a record of the root''s own type writes the root''s fields itself');

INSERT INTO fc_marks
SELECT 'B1 row positions',
       (SELECT ctid::TEXT FROM fcc_parties WHERE label = 'B1')
       || (SELECT x.ctid::TEXT FROM fcc_orgs_ext x JOIN fcc_parties p ON p.id = x.id WHERE p.label = 'B1')
       || (SELECT x.ctid::TEXT FROM fcc_banks_ext x JOIN fcc_parties p ON p.id = x.id WHERE p.label = 'B1');
UPDATE fcc_vendors SET terms = 'net90' WHERE label = 'B1';

SELECT is(
    (SELECT ctid::TEXT FROM fcc_parties WHERE label = 'B1')
    || (SELECT x.ctid::TEXT FROM fcc_orgs_ext x JOIN fcc_parties p ON p.id = x.id WHERE p.label = 'B1')
    || (SELECT x.ctid::TEXT FROM fcc_banks_ext x JOIN fcc_parties p ON p.id = x.id WHERE p.label = 'B1'),
    (SELECT v FROM fc_marks WHERE k = 'B1 row positions'),
    'an update of the extension''s own fields writes neither the root nor the subtype''s parts');

-- Deleting a bank record that has an extension, then without it.
INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B6', 'Bonn', 'DE6', 'BIC6');
INSERT INTO fcc_vendors (id, terms) SELECT id, 'net6' FROM fcc_parties WHERE label = 'B6';

SELECT throws_ok($$DELETE FROM fcc_banks WHERE label = 'B6'$$,
    '90251', NULL,
    'a subtype record with an extension cannot be deleted through its own view');

SELECT throws_ok($$DELETE FROM fcc_parties WHERE label = 'B6'$$,
    '90251', NULL,
    'a subtype record with an extension cannot be deleted through the root');

DELETE FROM fcc_vendors WHERE label = 'B6';
UPDATE entities
   SET validation_rules = '[{"code": "99603", "message": "a kept party cannot be deleted",
                             "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                        {"==": [{"var": "city"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fcc_parties';
UPDATE entities
   SET validation_rules = validation_rules
                          || '[{"code": "99604", "message": "a kept organization cannot be deleted",
                                "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                           {"==": [{"var": "vat"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fcc_orgs';
UPDATE entities
   SET validation_rules = '[{"code": "99605", "message": "a kept bank cannot be deleted",
                             "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                        {"==": [{"var": "bic"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fcc_banks';

UPDATE fcc_banks SET bic = 'keep' WHERE label = 'B6';

SELECT throws_ok($$DELETE FROM fcc_parties WHERE label = 'B6'$$,
    '99605', NULL,
    'once detached, a delete through the root runs the subtype''s delete rules');

UPDATE fcc_banks SET bic = 'BIC6', vat = 'keep' WHERE label = 'B6';

SELECT throws_ok($$DELETE FROM fcc_parties WHERE label = 'B6'$$,
    '99604', NULL,
    'once detached, a delete through the root runs the middle level''s delete rules');

UPDATE fcc_banks SET vat = 'DE6', city = 'keep' WHERE label = 'B6';

SELECT throws_ok($$DELETE FROM fcc_banks WHERE label = 'B6'$$,
    '99603', NULL,
    'once detached, a delete through the subtype''s view runs the root''s own rule trigger');

UPDATE fcc_banks SET city = 'Bonn' WHERE label = 'B6';

SELECT lives_ok($$DELETE FROM fcc_banks WHERE label = 'B6'$$,
    'with no rule refusing, the subtype record is deleted');

SELECT is(
    (SELECT count(*)::INTEGER FROM fcc_parties WHERE label = 'B6')
    + (SELECT count(*)::INTEGER FROM fcc_orgs_ext x WHERE NOT EXISTS (SELECT 1 FROM fcc_parties p WHERE p.id = x.id))
    + (SELECT count(*)::INTEGER FROM fcc_banks_ext x WHERE NOT EXISTS (SELECT 1 FROM fcc_parties p WHERE p.id = x.id)),
    0,
    'the delete removed every part of the record');

UPDATE entities SET validation_rules = '[]'::jsonb WHERE table_name IN ('fcc_parties', 'fcc_orgs', 'fcc_banks');

-- =====================================================
-- 8. A changed default and an attach
-- =====================================================
-- An attach through an extension tells a column the caller left out, which
-- holds the view's default, from a value the caller brought by comparing with
-- the column default written into the write routine. A changed default has to
-- reach that routine.

UPDATE fields SET default_value = 'Paris' WHERE table_name = 'fcc_parties' AND field_name = 'city';

SELECT lives_ok($$INSERT INTO fcc_vendors (id, terms) SELECT id, 'net15' FROM fcc_parties WHERE label = 'O1'$$,
    'after a root default change, an attach that leaves the field out is accepted');

SELECT is((SELECT city || '/' || terms FROM fcc_vendors WHERE label = 'O1'), 'Oslo/net15',
    'after a root default change, the attach keeps the stored value');

-- =====================================================
-- 9. References from other entities
-- =====================================================
-- A reference to a subtype points at its part and reads its label through the
-- subtype's view, which a rebuild replaces. fcx_notes cascades, fcx_memos
-- clears; both were created in step 4.

UPDATE fcc_parties SET city = 'Bern' WHERE label = 'B1';
INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B8', 'Brig', 'CH8', 'BIC8');
INSERT INTO fcx_notes (label, bank_id) SELECT 'N8', id FROM fcc_parties WHERE label = 'B8';
INSERT INTO fcx_memos (label, bank_id) SELECT 'M8', id FROM fcc_parties WHERE label = 'B8';

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fcx_notes n WHERE n.label = 'N1'$$), 'Bern',
    'a reference to a subtype resolves its label');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_parties', 'fccref', 'Extra', 'text', 120);

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fcx_notes n WHERE n.label = 'N1'$$), 'Bern',
    'the label still resolves after a family rebuild replaced the subtype''s view and its _label');

-- =====================================================
-- 10. Objects built on family views
-- =====================================================
-- The family refresh replaces every view of a family, and PostgreSQL drops
-- what depends on a view with it. An object of another author built on a
-- family view - a report view, say - would vanish without a word on a field
-- add, so a change that rebuilds the family is refused while one exists, and
-- the refusal names it. The dictionary's own objects do not count, and a view
-- over the root table is not touched by a rebuild at all.

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_parties', 'fccspare', 'Spare', 'text', 130);

RESET ROLE;
CREATE VIEW public.fcc_bank_report AS SELECT id, label, bic FROM public.fcc_banks;
SELECT authenticate_as('user3');

INSERT INTO fc_marks VALUES ('before a view on a family view', pg_temp.fc_snapshot('fcc_parties'));

SELECT is(pg_temp.sqlstate_of($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                                VALUES ('fcc_parties', 'fccextra2', 'Extra', 'text', 140)$$),
    '90256',
    'a root field add is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                            VALUES ('fcc_parties', 'fccextra2', 'Extra', 'text', 140)$$) LIKE '%fcc_bank_report%',
    'the refused root field add names that view');

SELECT is(pg_temp.sqlstate_of($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fcc_orgs' AND field_name = 'vat'$$),
    '90256',
    'a middle-level field change is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fcc_orgs' AND field_name = 'vat'$$)
          LIKE '%fcc_bank_report%',
    'the refused middle-level field change names that view');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET table_name = 'fcc_people' WHERE table_name = 'fcc_parties'$$),
    '90256',
    'a root rename is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$UPDATE entities SET table_name = 'fcc_people' WHERE table_name = 'fcc_parties'$$)
          LIKE '%fcc_bank_report%',
    'the refused root rename names that view');

-- A field delete and a searchable change drop, with CASCADE, columns the views
-- show before the family is rebuilt; a prefix change and a change of a level's
-- rules rebuild the family too. Each is refused the same way.
SELECT is(pg_temp.sqlstate_of($$DELETE FROM fields WHERE table_name = 'fcc_parties' AND field_name = 'fccspare'$$),
    '90256',
    'a root field delete is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of($$UPDATE fields SET searchable = TRUE WHERE table_name = 'fcc_parties' AND field_name = 'fccspare'$$),
    '90256',
    'a searchable change on the root is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_prefix = 'fccptyother' WHERE table_name = 'fcc_parties'$$),
    '90256',
    'a root prefix change is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of(
    $$UPDATE entities
         SET validation_rules = '[{"code": "99111", "message": "always passes", "jsonlogic": true}]'::jsonb
       WHERE table_name = 'fcc_orgs'$$),
    '90256',
    'rules added to a middle level are refused while a view of another author is built on a family view');

-- Once more outside pg_temp.sqlstate_of, which rolls a statement back whatever
-- it did, so the comparison below sees what a refused change leaves behind.
SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                   VALUES ('fcc_parties', 'fccextra2', 'Extra', 'text', 140)$$,
    '90256', NULL,
    'a root field add is refused while a view of another author is built on a family view');

SELECT is(pg_temp.fc_snapshot('fcc_parties'), (SELECT v FROM fc_marks WHERE k = 'before a view on a family view'),
    'the refused change leaves every view, routine and trigger of the family as it was');

SELECT ok(to_regclass('public.fcc_bank_report') IS NOT NULL,
    'the refused change leaves the view built on the family in place');

RESET ROLE;
DROP VIEW public.fcc_bank_report;
SELECT authenticate_as('user3');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fcc_parties', 'fccmore', 'More', 'text', 150)$$,
    'once the view is dropped, the root field add goes through');

SELECT lives_ok($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fcc_orgs' AND field_name = 'vat'$$,
    'once the view is dropped, the middle-level field change goes through');

-- The dictionary's own objects on a family view: fcx_notes references
-- fcc_banks, and a select_rule.
UPDATE entities SET select_rule = '{"!=": [{"var": "bic"}, "never"]}'::jsonb WHERE table_name = 'fcc_banks';

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fcc_parties', 'fcclast', 'Last', 'text', 160)$$,
    'the family''s own views and routines, a referencing entity''s label function and a select_rule block no change');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'fcc_banks';

-- A view over the root table.
RESET ROLE;
CREATE VIEW public.fcc_party_report AS SELECT id, label FROM public.fcc_parties;
SELECT authenticate_as('user3');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fcc_parties', 'fccagain', 'Again', 'text', 170)$$,
    'a view over the root table does not block a root field add, as for a plain entity');

SELECT ok(to_regclass('public.fcc_party_report') IS NOT NULL,
    'the view over the root table survives the root field add');

RESET ROLE;
DROP VIEW public.fcc_party_report;
SELECT authenticate_as('user3');

-- =====================================================
-- 11. The root's order column, and renames
-- =====================================================
-- The root takes an order column, which its rename has to carry as well. A
-- rename carries through ON UPDATE CASCADE to id_refentity, and the family
-- is rebuilt under the new names: the dispatch, the delete guard, the
-- select_rule routines that read a base, the foreign keys and label functions
-- of entities that reference a member. The root's label column has changed
-- above, which the rename's writes to the descendants' rows have to accept.

-- The root's order column is no field: it is in no view, and a record created
-- through a subtype still gets a position.
SELECT lives_ok($$UPDATE entities SET order_column = 'fccpos' WHERE table_name = 'fcc_parties'$$,
    'a root with subtypes may take an order column');

SELECT is(pg_temp.fc_with_column(ARRAY['fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors'], 'fccpos'),
    '',
    'the root''s order column is in no view');

INSERT INTO fcc_banks (label, city, vat, bic) VALUES ('B9', 'Bari', 'IT8', 'BIC9');

SELECT is(pg_temp.value_of($$SELECT (fccpos > 0)::TEXT FROM fcc_parties WHERE label = 'B9'$$), 'true',
    'a record created through a subtype gets a position in the root''s order column');

UPDATE entities SET select_rule = '{"!=": [{"var": "city"}, "never"]}'::jsonb
 WHERE table_name IN ('fcc_orgs', 'fcc_vendors');
INSERT INTO fc_marks SELECT 'orgs', count(*)::TEXT FROM fcc_orgs;
INSERT INTO fc_marks SELECT 'vendors', count(*)::TEXT FROM fcc_vendors;

SELECT lives_ok($$UPDATE entities SET table_name = 'fcc_people' WHERE table_name = 'fcc_parties'$$,
    'after the label column change, and with no view of another author on its views, the root is renamed');

SELECT is(
    (SELECT string_agg(table_name || '>' || id_refentity, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors')),
    'fcc_banks>fcc_orgs, fcc_orgs>fcc_people, fcc_persons>fcc_people, fcc_vendors>fcc_people',
    'root rename: the base of every child follows');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fcc_parties')
    AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fcc_people')
    AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fcc_people') AND tgname = 'a_is_a_dispatch'),
    'root rename: the dispatch routine is rebuilt under the new name');

SELECT is(
    (SELECT count(*)::INTEGER FROM (
        SELECT relname::TEXT FROM pg_class WHERE relname LIKE '%fcc\_parties%'
        UNION ALL SELECT proname::TEXT FROM pg_proc WHERE proname LIKE '%fcc\_parties%' OR prosrc LIKE '%fcc\_parties%'
        UNION ALL SELECT tgname::TEXT FROM pg_trigger WHERE tgname LIKE '%fcc\_parties%'
        UNION ALL SELECT polname::TEXT FROM pg_policy WHERE polname LIKE '%fcc\_parties%'
        UNION ALL SELECT conname::TEXT FROM pg_constraint WHERE conname LIKE '%fcc\_parties%') s),
    0,
    'root rename: nothing is left under the old name, generated routine bodies included');

SELECT * FROM pg_temp.fc_checks_on('after a root rename',
    'fcc_people', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_vendors', 'fcc_parties', 'fcc_');

SELECT authenticate_as('user2');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fcc_orgs$$), (SELECT v FROM fc_marks WHERE k = 'orgs'),
    'after a root rename, a child with a select_rule is still readable');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fcc_vendors$$), (SELECT v FROM fc_marks WHERE k = 'vendors'),
    'after a root rename, an extension with a select_rule is still readable');

SELECT authenticate_as('user3');

SELECT is(
    (SELECT string_agg(p.proname::TEXT, ', ' ORDER BY p.proname) FROM pg_proc p
      WHERE p.proname IN ('select_rule_fcc_orgs', 'select_rule_fcc_vendors') AND p.pronargs = 2
        AND p.prosrc LIKE '%fcc\_people%' AND p.prosrc NOT LIKE '%fcc\_parties%'),
    'select_rule_fcc_orgs, select_rule_fcc_vendors',
    'after a root rename, their select_rule routines read the root under its new name');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name IN ('fcc_orgs', 'fcc_vendors');

-- A has_a rename.
UPDATE entities SET table_name = 'fcc_suppliers' WHERE table_name = 'fcc_vendors';

SELECT is(pg_temp.fc_args('fcc_people', 'a_has_a_guard'), 'id,fcc_suppliers,',
    'has_a rename: the base''s delete guard names the extension under its new name');

SELECT throws_ok($$DELETE FROM fcc_people WHERE label = 'B1'$$,
    '90251', NULL,
    'has_a rename: a base record with an extension still cannot be deleted');

SELECT * FROM pg_temp.fc_checks_on('after a has_a rename',
    'fcc_people', 'fcc_orgs', 'fcc_banks', 'fcc_persons', 'fcc_suppliers', 'fcc_vendors', 'fcc_');

-- A middle-level rename: the grandchild's select_rule reads it by name.
UPDATE entities SET select_rule = '{"!=": [{"var": "vat"}, "never"]}'::jsonb WHERE table_name = 'fcc_banks';
UPDATE fc_marks SET v = (SELECT count(*)::TEXT FROM fcc_banks) WHERE k = 'banks';
UPDATE entities SET table_name = 'fcc_companies' WHERE table_name = 'fcc_orgs';
SELECT authenticate_as('user2');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fcc_banks$$), (SELECT v FROM fc_marks WHERE k = 'banks'),
    'after a middle level''s rename, the grandchild with a select_rule is still readable');

SELECT authenticate_as('user3');

SELECT is(
    (SELECT count(*)::INTEGER FROM pg_proc p
      WHERE p.proname = 'select_rule_fcc_banks' AND p.pronargs = 2
        AND p.prosrc LIKE '%fcc\_companies%' AND p.prosrc NOT LIKE '%fcc\_orgs%'),
    1,
    'after a middle level''s rename, the grandchild''s select_rule routine reads it under its new name');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'fcc_banks';

SELECT * FROM pg_temp.fc_checks_on('after a middle-level rename',
    'fcc_people', 'fcc_companies', 'fcc_banks', 'fcc_persons', 'fcc_suppliers', 'fcc_orgs', 'fcc_');

-- A subtype rename: the foreign keys to it and the label functions reading it.
UPDATE fcc_people SET city = 'Bern' WHERE label = 'B1';
UPDATE entities SET table_name = 'fcc_branches' WHERE table_name = 'fcc_banks';

SELECT is(
    (SELECT string_agg(c.conname || '->' || c.confrelid::regclass::TEXT, ', ' ORDER BY c.conname)
       FROM pg_constraint c WHERE c.conname IN ('fcx_notes_bank_id_fkey', 'fcx_memos_bank_id_fkey')),
    'fcx_memos_bank_id_fkey->fcc_branches_ext, fcx_notes_bank_id_fkey->fcc_branches_ext',
    'a subtype rename: the foreign keys to it target its renamed part');

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fcx_notes n WHERE n.label = 'N1'$$), 'Bern',
    'a subtype rename: the label still resolves');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bank_id_label' AND pronargs = 1
               AND proargtypes[0] = to_regtype('public.fcx_notes')::oid
               AND prosrc LIKE '%fcc\_branches%' AND prosrc NOT LIKE '%fcc\_banks%'),
    'a subtype rename: the label function is rebuilt to read the subtype under its new name');

SELECT * FROM pg_temp.fc_checks_on('after a subtype rename',
    'fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_banks', 'fcc_');

DELETE FROM fcc_people WHERE label = 'B8';

SELECT is(
    (SELECT count(*) FROM fcx_notes WHERE label = 'N8')::TEXT || '/'
    || (SELECT coalesce(bank_id::TEXT, 'cleared') FROM fcx_memos WHERE label = 'M8'),
    '0/cleared',
    'a delete through the root runs the cascading and the clearing references to the subtype');

DELETE FROM entities WHERE table_name IN ('fcx_notes', 'fcx_memos');


-- =====================================================
-- 12. Taking the family apart; is_child; modules
-- =====================================================
-- A family is taken apart from the bottom: an entity goes once nothing is
-- based on it and its records are gone, and the rest of the family is rebuilt
-- without it. A refused delete drops nothing.

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fcc_companies'$$,
    '90248', NULL,
    'a middle level with a child cannot be deleted');

SELECT ok(pg_temp.fc_intact(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers']),
    'the refused delete of the middle level dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fcc_suppliers'$$,
    '90247', NULL,
    'an extension with records cannot be deleted');

SELECT ok(pg_temp.fc_intact(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers']),
    'the refused delete of the extension dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fcc_people'$$,
    '90248', NULL,
    'a root with records and dependents of both kinds is refused for its dependents first');

SELECT ok(pg_temp.fc_intact(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers']),
    'the refused delete of the root dropped nothing');

-- A second extension, and every level emptied through its own entity.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                      view_permission, edit_permission)
VALUES ('fcc_clients', 'Client', 'Clients', (SELECT id FROM modules WHERE module_name = 'fcc_mod'), 'has_a',
        'fcc_people', 'nwind:view', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fcc_clients', 'credit', 'Credit', 'int32', 30);

DELETE FROM fcc_suppliers;
DELETE FROM fcc_branches;
DELETE FROM fcc_companies;
DELETE FROM fcc_persons;
DELETE FROM fcc_people;

SELECT is((SELECT count(*)::INTEGER FROM fcc_people), 0,
    'every level is emptied through its own entity');

-- is_child follows the family: a level is a child when it or a level above
-- it has a parent field. A parent field is NOT NULL, so it is added while the
-- family has no records.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fcx_groups', 'Group', 'Groups', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_people', 'group_id', 'Group', 'parent', 'fcx_groups', 'cascade', 180);

SELECT is(pg_temp.fc_is_child(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_clients']),
    'fcc_branches=true, fcc_clients=true, fcc_companies=true, fcc_people=true, fcc_persons=true, fcc_suppliers=true',
    'is_child: a parent field on the root makes every level a child');

UPDATE fields SET format = 'reference' WHERE table_name = 'fcc_people' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_clients']),
    'fcc_branches=false, fcc_clients=false, fcc_companies=false, fcc_people=false, fcc_persons=false, fcc_suppliers=false',
    'is_child: changing it to a plain reference clears every level');

UPDATE fields SET format = 'parent' WHERE table_name = 'fcc_people' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_clients']),
    'fcc_branches=true, fcc_clients=true, fcc_companies=true, fcc_people=true, fcc_persons=true, fcc_suppliers=true',
    'is_child: changing it back to parent sets every level again');

DELETE FROM fields WHERE table_name = 'fcc_people' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_clients']),
    'fcc_branches=false, fcc_clients=false, fcc_companies=false, fcc_people=false, fcc_persons=false, fcc_suppliers=false',
    'is_child: deleting it clears every level');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_companies', 'org_group_id', 'Organization Group', 'parent', 'fcx_groups', 'restrict', 60);

SELECT is(pg_temp.fc_is_child(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers', 'fcc_clients']),
    'fcc_branches=true, fcc_clients=false, fcc_companies=true, fcc_people=false, fcc_persons=false, fcc_suppliers=false',
    'is_child: a parent field on a middle level makes it and the level below it children, not the root or the other branch');

DELETE FROM fields WHERE table_name = 'fcc_companies' AND field_name = 'org_group_id';
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fcc_people', 'group_id', 'Group', 'parent', 'fcx_groups', 'cascade', 180);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('fcc_teams', 'Team', 'Teams', 1, 'is_a', 'fcctea', 'fcc_people');

SELECT is((SELECT is_child FROM entities WHERE table_name = 'fcc_teams'), TRUE,
    'is_child: a subtype created under a root that is a child is created as a child');

DELETE FROM entities WHERE table_name = 'fcc_teams';
DELETE FROM fields WHERE table_name = 'fcc_people' AND field_name = 'group_id';

-- Empty, the family still refuses to lose a base under its dependents.
SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fcc_companies'$$,
    '90248', NULL,
    'a middle level with a child cannot be deleted even when every level is empty');

SELECT ok(pg_temp.fc_intact(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers']),
    'the refused delete of the empty middle level dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fcc_people'$$,
    '90248', NULL,
    'an empty root with dependents cannot be deleted');

SELECT ok(pg_temp.fc_intact(ARRAY['fcc_people', 'fcc_companies', 'fcc_branches', 'fcc_persons', 'fcc_suppliers']),
    'the refused delete of the empty root dropped nothing');

-- A module delete takes the family's views as well.
RESET ROLE;
CREATE VIEW public.fcc_company_report AS SELECT id FROM public.fcc_companies;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM modules WHERE module_name = 'fcc_mod'$$), '90256',
    'a module delete is refused while a view of another author is built on one of its family views');

RESET ROLE;
DROP VIEW public.fcc_company_report;
SELECT authenticate_as('user3');

-- The extensions.
INSERT INTO fcc_people (label) VALUES ('P2');
INSERT INTO fcc_suppliers (id, terms) SELECT id, 'net30' FROM fcc_people WHERE label = 'P2';

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_clients'$$,
    'an empty extension that is not the last one is deleted');

SELECT ok(
    to_regclass('public.fcc_clients') IS NULL AND to_regclass('public.fcc_clients_ext') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('record_write_fcc_clients', 'view_write_fcc_clients')),
    'the deleted extension''s view, part and routines are gone');

SELECT is(pg_temp.fc_args('fcc_people', 'a_has_a_guard'), 'id,fcc_suppliers,',
    'the base''s delete guard is rebuilt with the remaining extension');

SELECT throws_ok($$DELETE FROM fcc_people WHERE label = 'P2'$$,
    '90251', NULL,
    'the rebuilt guard still protects a base record with an extension');

DELETE FROM fcc_suppliers;

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_suppliers'$$,
    'the last extension, once empty, is deleted');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fcc_people') AND tgname = 'a_has_a_guard'),
    'with no extension left, the base loses its delete guard');

SELECT lives_ok($$DELETE FROM fcc_people WHERE label = 'P2'$$,
    'a base record can be deleted again');

-- The grandchild: deleting it rebuilds its base's family, and drops its own
-- view.
RESET ROLE;
CREATE VIEW public.fcc_company_report AS SELECT id, vat FROM public.fcc_companies;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM entities WHERE table_name = 'fcc_branches'$$), '90256',
    'deleting a subtype is refused while a view of another author is built on its base''s view');

SELECT ok(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'fcc_branches'$$) LIKE '%fcc_company_report%',
    'the refused subtype delete names the view on its base''s view');

RESET ROLE;
DROP VIEW public.fcc_company_report;
CREATE VIEW public.fcc_branch_report AS SELECT id, bic FROM public.fcc_branches;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM entities WHERE table_name = 'fcc_branches'$$), '90256',
    'deleting a subtype is refused while a view of another author is built on its own view');

SELECT ok(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'fcc_branches'$$) LIKE '%fcc_branch_report%',
    'the refused subtype delete names the view on its own view');

SELECT ok(to_regclass('public.fcc_branches') IS NOT NULL,
    'the refused subtype is still there');

RESET ROLE;
DROP VIEW public.fcc_branch_report;
SELECT authenticate_as('user3');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_branches'$$,
    'an empty grandchild is deleted');

SELECT ok(
    to_regclass('public.fcc_branches') IS NULL AND to_regclass('public.fcc_branches_ext') IS NULL
    AND pg_temp.fc_args('fcc_people', 'typeid_assign') NOT LIKE '%fccbnk%',
    'the deleted grandchild''s relations are gone and the root no longer accepts its prefix');

-- The middle level, the last subtype, the root.
SELECT lives_ok($$INSERT INTO fcc_companies (label, city, vat) VALUES ('O2', 'Oulu', 'FI2')$$,
    'the middle level, rebuilt without its child, is written through its view');

SELECT is(pg_temp.fc_write($$UPDATE fcc_people SET city = 'Oslo' WHERE label = 'O2'$$,
                           $$SELECT city FROM fcc_companies WHERE label = 'O2'$$),
    'Oslo',
    'the middle level, rebuilt without its child, is written through the root');

DELETE FROM fcc_companies WHERE label = 'O2';

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_companies'$$,
    'the middle level, with no child and no records, is deleted');

SELECT is(pg_temp.fc_args('fcc_people', 'typeid_assign'), 'id,fccptynew,fccper,',
    'the root''s typeid_assign keeps the prefix of the remaining subtype only');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_persons'$$,
    'the last subtype is deleted');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fcc_people') AND tgname = 'a_is_a_dispatch')
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fcc_people'),
    'with no subtype left, the root loses its dispatch trigger and routine');

INSERT INTO fcc_people (label, city) VALUES ('P3', 'Pula');

SELECT is(pg_temp.fc_write($$UPDATE fcc_people SET city = 'Pola' WHERE label = 'P3'$$,
                           $$SELECT city || '/' || common.typeid_prefix(id) FROM fcc_people WHERE label = 'P3'$$),
    'Pola/fccptynew',
    'the former root is written like any typeid entity');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fcc_people'$$,
    'the former root is deleted like a plain entity, with its records');

SELECT is(
    (SELECT count(*)::INTEGER FROM (
        SELECT relname::TEXT FROM pg_class WHERE relname LIKE '%fcc\_%'
        UNION ALL SELECT proname::TEXT FROM pg_proc WHERE proname LIKE '%fcc\_%' OR prosrc LIKE '%fcc\_%'
        UNION ALL SELECT tgname::TEXT FROM pg_trigger WHERE tgname LIKE '%fcc\_%'
        UNION ALL SELECT polname::TEXT FROM pg_policy WHERE polname LIKE '%fcc\_%') s),
    0,
    'no relation, routine, trigger or policy of the family is left');

-- A family across two modules: a module whose root has a child in another
-- module cannot go first.
INSERT INTO modules (module_name) VALUES ('fcm_mod_a'), ('fcm_mod_b');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fcm_parties', 'Party', 'Parties', (SELECT id FROM modules WHERE module_name = 'fcm_mod_a'), 'typeid', 'fcmpty');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('fcm_orgs', 'Organization', 'Organizations', (SELECT id FROM modules WHERE module_name = 'fcm_mod_b'),
        'is_a', 'fcmorg', 'fcm_parties');

SELECT throws_ok($$DELETE FROM modules WHERE module_name = 'fcm_mod_a'$$,
    '90248', NULL,
    'a module whose root has a child in another module cannot be deleted');

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'fcm_mod_b'$$,
    'the module with the child can be deleted');

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'fcm_mod_a'$$,
    'then the module with the root can be deleted');

SELECT ok(
    to_regclass('public.fcm_parties') IS NULL AND to_regclass('public.fcm_orgs') IS NULL
    AND to_regclass('public.fcm_orgs_ext') IS NULL
    AND NOT EXISTS (SELECT 1 FROM entities WHERE table_name IN ('fcm_parties', 'fcm_orgs')),
    'the two module deletes took both entities and every relation');

-- =====================================================
-- 13. A family keyed by pid
-- =====================================================
-- A key column is fixed when the root is created (90253), so no change of the
-- family above reaches a key column other than id.

SELECT pg_temp.fc_build('fck_', 'fck', 1, 'pid');

SELECT is(
    (SELECT string_agg(table_name || '=' || id_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fck_parties', 'fck_orgs', 'fck_banks', 'fck_persons', 'fck_vendors')),
    'fck_banks=pid, fck_orgs=pid, fck_parties=pid, fck_persons=pid, fck_vendors=pid',
    'a root keyed by pid: every level inherits its key column');

SELECT is(
    (SELECT string_agg(c.relname || ':' || a.attname, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fck_orgs', 'fck_orgs_ext', 'fck_banks', 'fck_banks_ext',
                          'fck_persons', 'fck_persons_ext', 'fck_vendors', 'fck_vendors_ext')
        AND a.attnum = 1),
    'fck_banks:pid, fck_banks_ext:pid, fck_orgs:pid, fck_orgs_ext:pid, fck_persons:pid, fck_persons_ext:pid, fck_vendors:pid, fck_vendors_ext:pid',
    'a root keyed by pid: every view and every part is keyed by pid');

SELECT * FROM pg_temp.fc_checks('a family keyed by pid', 'fck_');

SELECT lives_ok($$DELETE FROM fck_parties WHERE label = 'R1'$$,
    'a root keyed by pid: a delete through the root reaches the subtype record');

SELECT is((SELECT count(*)::INTEGER FROM fck_persons_ext), 0,
    'a root keyed by pid: and removes its part');

SELECT * FROM finish();
ROLLBACK;
