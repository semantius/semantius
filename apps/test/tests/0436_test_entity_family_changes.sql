-- Families: how an is_a / has_a family changes. Adding, changing or removing
-- a base (the root or a middle level) or a child - its entity row, its fields,
-- its records, its rules and permissions, the module that installs it - has to
-- reach every level: the views, the <entity>_ext columns, the generated write
-- routines, the triggers, the _label functions and get_schema. How a family is
-- built and written is pinned by 0435_test_entity_id_types.sql; this file pins
-- how it changes.
--
-- Every part builds its own copy of one family with pg_temp.fc_build, so no
-- part depends on what another one left behind:
--
--   <p>parties     typeid  (label, city)  view public:read  edit nwind:manage
--     <p>orgs      is_a    (vat)          view nwind:view   edit nwind:manage
--       <p>banks   is_a    (bic, tag)     view nwind:view   edit admin
--     <p>persons   is_a    (birth)        view nwind:view   edit nwind:manage
--     <p>vendors   has_a   (terms)        view nwind:view   edit nwind:manage
--
-- with one record per level - P1, O1, B1, R1 - and a vendor extension on B1,
-- so an is_a and a has_a entity share one base record. banks.tag is computed
-- as "T:" followed by the root's city. It follows a change of city only when
-- the bank's own write routine ran, which is what shows that a write reached
-- the record's own type.
--
-- user3 (admin) changes the dictionary. user2 holds nwind:view and
-- nwind:manage but not admin: it reads every level and writes every level but
-- banks.
--
-- A refusal is asserted with pg_temp.sqlstate_of, which rolls back whatever
-- the statement did even when it succeeds, so a change that went through
-- cannot alter what later assertions see. A read or a write that fails is
-- reported by pg_temp.value_of and pg_temp.fc_write as 'ERROR <sqlstate>', and
-- a statement whose failure would change later state runs in lives_ok, so
-- every assertion reports instead of ending the file.
--
--   PART 1  root and middle-level field changes
--   PART 2  the root's label
--   PART 3  the key column
--   PART 4  entity-level changes: labels, renames, prefixes, new subtypes, is_child
--   PART 5  rules and permissions
--   PART 6  an is_a and a has_a entity on one base record
--   PART 7  records
--   PART 8  references from other entities
--   PART 9  refused changes and the DDL audit
--   PART 10 dropping family entities
--   PART 11 objects built on family views
--
-- Everything is rolled back.

BEGIN;

SELECT plan(353);

-- =====================================================
-- Helpers
-- =====================================================
-- pg_temp functions take no EXECUTE grant: a function outside public and
-- common keeps the PUBLIC default, and every role may use the session's temp
-- schema, so they run as whichever user the test authenticated as.

-- Named values a later assertion compares with: snapshots, row positions,
-- audit log marks. Created by the connection's role and granted to the request
-- role, which writes most of them.
CREATE TEMP TABLE fc_marks (k TEXT PRIMARY KEY, v TEXT NOT NULL);
GRANT SELECT, INSERT, UPDATE, DELETE ON fc_marks TO semantius_user;

-- The standard family under the name prefix p and the TypeID prefix stem x,
-- with its records. p_key names the root's key column, which every level
-- inherits.
CREATE FUNCTION pg_temp.fc_build(p TEXT, x TEXT, p_key TEXT DEFAULT 'id')
RETURNS VOID LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_column,
                              view_permission, edit_permission)
        VALUES (%L, 'Party', 'Parties', 1, 'typeid', %L, %L, 'public:read', 'nwind:manage')$q$,
        p || 'parties', x || 'pty', p_key);
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'city', 'City', 'text', 30)$q$,
        p || 'parties');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Organization', 'Organizations', 1, 'is_a', %L, %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'orgs', x || 'org', p || 'parties');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'vat', 'VAT', 'text', 30)$q$,
        p || 'orgs');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Bank', 'Banks', 1, 'is_a', %L, %L, 'nwind:view', 'admin')$q$,
        p || 'banks', x || 'bnk', p || 'orgs');
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
        VALUES (%L, 'Person', 'Persons', 1, 'is_a', %L, %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'persons', x || 'per', p || 'parties');
    EXECUTE format($q$
        INSERT INTO fields (table_name, field_name, title, format, field_order)
        VALUES (%L, 'birth', 'Birth', 'date', 30)$q$,
        p || 'persons');

    EXECUTE format($q$
        INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                              view_permission, edit_permission)
        VALUES (%L, 'Vendor', 'Vendors', 1, 'has_a', %L, 'nwind:view', 'nwind:manage')$q$,
        p || 'vendors', p || 'parties');
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
END $fn$;

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

-- entities.is_child of the five standard members.
CREATE FUNCTION pg_temp.fc_is_child(p TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT string_agg(e.table_name || '=' || e.is_child::TEXT, ', ' ORDER BY e.table_name COLLATE "C")
      FROM entities e
     WHERE e.table_name = ANY (ARRAY[p || 'parties', p || 'orgs', p || 'banks', p || 'persons', p || 'vendors']);
$fn$;

-- TRUE while every entity row, the root table, and every view and part of
-- the five standard members exist.
CREATE FUNCTION pg_temp.fc_intact(p TEXT) RETURNS BOOLEAN LANGUAGE sql AS $fn$
    SELECT (SELECT count(*) FROM entities e
             WHERE e.table_name = ANY (ARRAY[p || 'parties', p || 'orgs', p || 'banks', p || 'persons', p || 'vendors'])) = 5
       AND to_regclass(format('public.%I', p || 'parties')) IS NOT NULL
       AND (SELECT bool_and(to_regclass(format('public.%I', p || m)) IS NOT NULL
                            AND to_regclass(format('public.%I', p || m || '_ext')) IS NOT NULL)
              FROM unnest(ARRAY['orgs', 'banks', 'persons', 'vendors']) AS m);
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

-- The messages a queue holds about one table.
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
-- p_root, named for p_step. Run as an administrator; checks 3 and 4 write.
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
-- already failed for it.
CREATE FUNCTION pg_temp.fc_checks_on(p_step TEXT, p_root TEXT, p_org TEXT, p_bank TEXT, p_person TEXT,
                                     p_vendor TEXT, p_old TEXT)
RETURNS SETOF TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_views TEXT[] := ARRAY[p_org, p_bank, p_person, p_vendor];
    v_key   TEXT;
    v_label TEXT;
    v_name  TEXT;
    v_rel   REGCLASS;
    v_out   TEXT;
    v_have  TEXT;
    v_want  TEXT;
    v_pat   TEXT;
BEGIN
    SELECT e.id_column, e.label_column INTO v_key, v_label FROM entities e WHERE e.table_name = p_root;
    v_key := coalesce(v_key, 'id');
    v_label := coalesce(v_label, 'label');

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
            format('UPDATE public.%I SET city = %L WHERE %I = %L', p_root, 'W-root', v_label, 'P1'),
            format('SELECT city FROM public.%I WHERE %I = %L', p_root, v_label, 'P1')),
        'org:' || pg_temp.fc_write(
            format('UPDATE public.%I SET vat = %L WHERE %I = %L', p_org, 'W-org', v_label, 'O1'),
            format('SELECT vat FROM public.%I WHERE %I = %L', p_org, v_label, 'O1')),
        'bank:' || pg_temp.fc_write(
            format('UPDATE public.%I SET bic = %L WHERE %I = %L', p_bank, 'W-bank', v_label, 'B1'),
            format('SELECT bic FROM public.%I WHERE %I = %L', p_bank, v_label, 'B1')),
        'person:' || pg_temp.fc_write(
            format('UPDATE public.%I SET birth = %L WHERE %I = %L', p_person, '2002-02-02', v_label, 'R1'),
            format('SELECT to_char(birth, ''YYYY-MM-DD'') FROM public.%I WHERE %I = %L', p_person, v_label, 'R1')),
        'vendor:' || pg_temp.fc_write(
            format('UPDATE public.%I SET terms = %L WHERE %I = %L', p_vendor, 'W-vendor', v_label, 'B1'),
            format('SELECT terms FROM public.%I WHERE %I = %L', p_vendor, v_label, 'B1')));
    RETURN NEXT is(v_have, 'root:W-root org:W-org bank:W-bank person:2002-02-02 vendor:W-vendor',
        p_step || ': a write through each level is stored');

    -- 4
    v_have := 'root:' || pg_temp.fc_write(
                  format('UPDATE public.%I SET city = %L WHERE %I = %L', p_root, 'D-root', v_label, 'B1'),
                  format('SELECT city || ''/'' || tag FROM public.%I WHERE %I = %L', p_bank, v_label, 'B1'))
              || ' org:' || pg_temp.fc_write(
                  format('UPDATE public.%I SET city = %L WHERE %I = %L', p_org, 'D-org', v_label, 'B1'),
                  format('SELECT city || ''/'' || tag FROM public.%I WHERE %I = %L', p_bank, v_label, 'B1'));
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

-- The checks on the standard family under the name prefix p.
CREATE FUNCTION pg_temp.fc_checks(p_step TEXT, p TEXT) RETURNS SETOF TEXT LANGUAGE sql AS $fn$
    SELECT * FROM pg_temp.fc_checks_on(p_step, p || 'parties', p || 'orgs', p || 'banks', p || 'persons',
                                       p || 'vendors', '');
$fn$;

-- =====================================================
-- PART 1: root and middle-level field changes
-- =====================================================
-- A statement on fields ends in the family refresh: every view below the
-- changed level shows its columns and every write routine writes them, so
-- after each change the whole family is checked.

SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc1_', 'fca');

SELECT * FROM pg_temp.fc_checks('the fixture', 'fc1_');

-- Add a root field.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc1_parties', 'fc1zone', 'Zone', 'text', 40);

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1zone'),
    'fc1_banks, fc1_orgs, fc1_persons, fc1_vendors',
    'root field add: every view shows the new column');

SELECT is(pg_temp.fc_write($$UPDATE fc1_banks SET fc1zone = 'north' WHERE label = 'B1'$$,
                           $$SELECT fc1zone FROM fc1_parties WHERE label = 'B1'$$),
    'north',
    'root field add: the column is written through the grandchild''s view into the root');

SELECT * FROM pg_temp.fc_checks('after a root field add', 'fc1_');

-- Rename it.
UPDATE fields SET field_name = 'fc1area' WHERE table_name = 'fc1_parties' AND field_name = 'fc1zone';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1zone')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1area'),
    ' | fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors',
    'root field rename: the root and every view show the column under its new name only');

SELECT is(pg_temp.value_of($$SELECT fc1area FROM fc1_banks WHERE label = 'B1'$$), 'north',
    'root field rename: the value is kept');

SELECT * FROM pg_temp.fc_checks_on('after a root field rename',
    'fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors', 'fc1zone');

-- Change its default: set on the root table, copied to every view.
UPDATE fields SET default_value = 'Nowhere' WHERE table_name = 'fc1_parties' AND field_name = 'fc1area';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attrdef d
       JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       JOIN pg_class c ON c.oid = d.adrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors')
        AND a.attname = 'fc1area'
        AND pg_get_expr(d.adbin, d.adrelid) LIKE '%Nowhere%'),
    'fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors',
    'root default change: the root table and every view carry the new default');

INSERT INTO fc1_banks (label, city, vat, bic) VALUES ('B2', 'Basel', 'CH2', 'BIC2');

SELECT is(pg_temp.value_of($$SELECT fc1area FROM fc1_parties WHERE label = 'B2'$$), 'Nowhere',
    'root default change: an insert through the grandchild that leaves the field out gets the default');

SELECT * FROM pg_temp.fc_checks('after a root default change', 'fc1_');

-- Change its title and description: every view carries the column comment.
UPDATE fields SET title = 'Area', description = 'Where it is'
 WHERE table_name = 'fc1_parties' AND field_name = 'fc1area';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors')
        AND a.attname = 'fc1area'
        AND col_description(c.oid, a.attnum::INTEGER) = E'Area (text)\n\nWhere it is'),
    'fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors',
    'root title and description change: the root table and every view carry the new column comment');

SELECT * FROM pg_temp.fc_checks('after a root title and description change', 'fc1_');

-- Delete it.
DELETE FROM fields WHERE table_name = 'fc1_parties' AND field_name = 'fc1area';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1area'),
    '',
    'root field delete: the column is gone from the root and every view');

SELECT * FROM pg_temp.fc_checks('after a root field delete', 'fc1_');

-- A format change to another format of the same type is a comment change.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc1_parties', 'fc1mail', 'Mail', 'text', 50);
UPDATE fields SET format = 'email' WHERE table_name = 'fc1_parties' AND field_name = 'fc1mail';

SELECT is(
    (SELECT string_agg(c.relname::TEXT, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors')
        AND a.attname = 'fc1mail'
        AND col_description(c.oid, a.attnum::INTEGER) = 'Mail (email)'),
    'fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors',
    'root format change of the same type: allowed, and every view''s column comment names the new format');

SELECT * FROM pg_temp.fc_checks('after a root format change of the same type', 'fc1_');

-- A format change to another type is refused before anything is rebuilt.
INSERT INTO fc_marks VALUES ('fc1 before int32', pg_temp.fc_snapshot('fc1_parties'));

SELECT throws_ok($$UPDATE fields SET format = 'int32' WHERE table_name = 'fc1_parties' AND field_name = 'fc1mail'$$,
    '90223', NULL,
    'root format change of another type: refused');

SELECT is(pg_temp.fc_snapshot('fc1_parties'), (SELECT v FROM fc_marks WHERE k = 'fc1 before int32'),
    'root format change of another type: every view, routine and trigger of the family is as it was');

-- A root reference field: its <fk>_label is a function of every view.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fc1_owners', 'Owner', 'Owners', 1),
       ('fc1_owners2', 'Second Owner', 'Second Owners', 1);
INSERT INTO fc1_owners (id, label) VALUES (1, 'Ann');
INSERT INTO fc1_owners2 (id, label) VALUES (1, 'Zed');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc1_parties', 'owner_id', 'Owner', 'reference', 'fc1_owners', 'restrict', 60);
UPDATE fc1_banks SET owner_id = 1 WHERE label = 'B1';

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'owner_id_label' AND pronargs = 1
               AND proargtypes[0] = to_regtype('public.fc1_banks')::oid)
    AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.fc1_banks'::regclass AND attname = 'owner_id_label'),
    'root reference field: the grandchild''s view gets owner_id_label as a function, not a column');

SELECT is(pg_temp.value_of($$SELECT public.owner_id_label(b) FROM fc1_banks b WHERE b.label = 'B1'$$), 'Ann',
    'root reference field: the grandchild''s owner_id_label resolves the referenced record');

SELECT * FROM pg_temp.fc_checks('after a root reference field add', 'fc1_');

UPDATE fields SET reference_table = 'fc1_owners2' WHERE table_name = 'fc1_parties' AND field_name = 'owner_id';

SELECT is(pg_temp.value_of($$SELECT public.owner_id_label(b) FROM fc1_banks b WHERE b.label = 'B1'$$), 'Zed',
    'root reference field: a changed reference_table repoints the label function of every level');

SELECT * FROM pg_temp.fc_checks('after a root reference field is repointed', 'fc1_');

DELETE FROM fields WHERE table_name = 'fc1_parties' AND field_name = 'owner_id';

SELECT is(
    (SELECT count(*)::INTEGER FROM pg_proc
      WHERE proname = 'owner_id_label' AND pronargs = 1
        AND proargtypes[0] IN (SELECT to_regtype('public.' || n)::oid
                                 FROM unnest(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors']) AS n)),
    0,
    'root reference field delete: no level keeps its label function');

SELECT * FROM pg_temp.fc_checks('after a root reference field delete', 'fc1_');

-- Delete modes of root fields. A referential action runs inside a trigger,
-- where the dispatch leaves the write to the action, so it reaches the root
-- row only.
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fc1_regions', 'Region', 'Regions', 1);
INSERT INTO fc1_regions (label) VALUES ('RA'), ('RB');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc1_parties', 'region_id', 'Region', 'reference', 'fc1_regions', 'cascade', 70);
UPDATE fc1_parties SET region_id = (SELECT id FROM fc1_regions WHERE label = 'RA') WHERE label = 'B2';
UPDATE fc1_parties SET region_id = (SELECT id FROM fc1_regions WHERE label = 'RB') WHERE label = 'B1';

SELECT throws_ok($$DELETE FROM fc1_regions WHERE label = 'RA'$$,
    '23503', NULL,
    'a cascading root reference cannot delete the root row of a subtype record from under its parts');

SELECT throws_ok($$DELETE FROM fc1_regions WHERE label = 'RB'$$,
    '90251', NULL,
    'a cascading root reference cannot delete a record that still has an extension');

UPDATE fields SET reference_delete_mode = 'clear' WHERE table_name = 'fc1_parties' AND field_name = 'region_id';
DELETE FROM fc1_regions WHERE label = 'RA';

SELECT is(pg_temp.value_of($$SELECT coalesce(region_id::TEXT, 'cleared') FROM fc1_banks WHERE label = 'B2'$$), 'cleared',
    'a clearing root reference clears the column of a subtype record whose referenced record is deleted');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc1_orgs', 'org_region_id', 'Organization Region', 'reference', 'fc1_regions', 'restrict', 50);

SELECT throws_ok(
    $$UPDATE fields SET reference_delete_mode = 'cascade' WHERE table_name = 'fc1_orgs' AND field_name = 'org_region_id'$$,
    '90249', NULL,
    'a reference field of a subtype cannot be changed to cascade');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc1_vendors', 'vendor_region_id', 'Vendor Region', 'reference', 'fc1_regions', 'cascade', 50);
UPDATE fc1_vendors SET vendor_region_id = (SELECT id FROM fc1_regions WHERE label = 'RB') WHERE label = 'B1';
DELETE FROM fc1_regions WHERE label = 'RB';

SELECT is(
    (SELECT count(*) FROM fc1_vendors WHERE label = 'B1')::TEXT || '/' || (SELECT count(*) FROM fc1_banks WHERE label = 'B1')::TEXT,
    '0/1',
    'a cascading reference of an extension only detaches the extension; the record stays');

INSERT INTO fc1_vendors (id, terms) SELECT id, 'net30' FROM fc1_parties WHERE label = 'B1';

-- A unique root field is unique across the records of every level.
INSERT INTO fields (table_name, field_name, title, format, field_order, unique_value)
VALUES ('fc1_parties', 'code', 'Code', 'text', 80, TRUE);
UPDATE fc1_banks SET code = 'C1' WHERE label = 'B1';

SELECT throws_ok($$INSERT INTO fc1_persons (label, code) VALUES ('R2', 'C1')$$,
    '23505', NULL,
    'a unique root field: a person cannot repeat a bank''s value');

-- Field names are unique along a chain of bases, on the rename path too.
SELECT throws_ok($$UPDATE fields SET field_name = 'bic' WHERE table_name = 'fc1_parties' AND field_name = 'code'$$,
    '90243', NULL,
    'a root field cannot be renamed to the name of a field of the grandchild');

SELECT throws_ok($$UPDATE fields SET field_name = 'code' WHERE table_name = 'fc1_banks' AND field_name = 'bic'$$,
    '90243', NULL,
    'a grandchild''s field cannot be renamed to the name of a root field');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc1_persons', 'pnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'fc1 org and bank columns', pg_temp.fc_cols('fc1_orgs') || ' | ' || pg_temp.fc_cols('fc1_banks');

SELECT lives_ok($$UPDATE fields SET field_name = 'bic' WHERE table_name = 'fc1_persons' AND field_name = 'pnote'$$,
    'a subtype may rename a field to a name its sibling''s branch uses: the two never share a record');

SELECT is(pg_temp.fc_cols('fc1_orgs') || ' | ' || pg_temp.fc_cols('fc1_banks'),
    (SELECT v FROM fc_marks WHERE k = 'fc1 org and bank columns'),
    'a sibling''s field change leaves the columns of the other branch as they were');

-- A middle-level field reaches the level below it, not the sibling branch or
-- the extension.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc1_orgs', 'fc1onote', 'Organization Note', 'text', 60);

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1onote'),
    'fc1_banks, fc1_orgs',
    'middle-level field add: the level and the one below it show it, the sibling branch and the extension do not');

SELECT * FROM pg_temp.fc_checks('after a middle-level field add', 'fc1_');

UPDATE fields SET field_name = 'fc1omemo' WHERE table_name = 'fc1_orgs' AND field_name = 'fc1onote';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1onote')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1omemo'),
    ' | fc1_banks, fc1_orgs',
    'middle-level field rename: the level and the one below it show the new name only');

SELECT * FROM pg_temp.fc_checks_on('after a middle-level field rename',
    'fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors', 'fc1onote');

DELETE FROM fields WHERE table_name = 'fc1_orgs' AND field_name = 'fc1omemo';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_orgs', 'fc1_orgs_ext', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'fc1omemo'),
    '',
    'middle-level field delete: gone from its part and from every view');

SELECT * FROM pg_temp.fc_checks('after a middle-level field delete', 'fc1_');

-- Searchable on the root.
UPDATE fields SET searchable = FALSE WHERE table_name = 'fc1_parties' AND field_name = 'label';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'search_vector'),
    '',
    'searchable: with no searchable field in the family, no level has a search_vector');

UPDATE fields SET searchable = TRUE WHERE table_name = 'fc1_parties' AND field_name = 'city';

SELECT is(pg_temp.fc_with_column(ARRAY['fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors'], 'search_vector')
          || ' / ' || (SELECT string_agg(table_name, ', ' ORDER BY table_name COLLATE "C") FROM entities
                        WHERE table_name IN ('fc1_parties', 'fc1_orgs', 'fc1_banks', 'fc1_persons', 'fc1_vendors')
                          AND searchable),
    'fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors / fc1_banks, fc1_orgs, fc1_parties, fc1_persons, fc1_vendors',
    'searchable: a searchable root field makes every level searchable and gives every view a search_vector');

UPDATE fc1_parties SET city = 'Zurichfcone' WHERE label = 'B1';

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fc1_banks WHERE search_vector @@ to_tsquery('simple', 'zurichfcone')$$),
    '1',
    'searchable: a search through the grandchild''s view finds text stored in the root');

SELECT * FROM pg_temp.fc_checks('after a searchable change on the root', 'fc1_');

-- get_schema of the grandchild describes the root field as it is now.
UPDATE fields SET title = 'Town' WHERE table_name = 'fc1_parties' AND field_name = 'city';

SELECT is(
    ((public.get_schema('fc1_banks')::jsonb) #>> '{properties,city,title}')
    || ' from ' || ((public.get_schema('fc1_banks')::jsonb) #>> '{properties,city,inherited_from}'),
    'Town from fc1_parties',
    'get_schema of the grandchild shows a root field''s new title, inherited from the root');

-- =====================================================
-- PART 2: the root's label
-- =====================================================
-- Every level's records are the root's records, so every level's label column
-- is the root's (90242 holds a derived entity to it). A change of the root's
-- label column, by a rename of its field or directly, has to reach every
-- level, or every later write to a derived entity's row is refused.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc2_', 'fcb');

-- A rename of the root's label field.
UPDATE fields SET field_name = 'fc2title' WHERE table_name = 'fc2_parties' AND field_name = 'label';

SELECT is(
    (SELECT string_agg(table_name || '=' || label_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors')),
    'fc2_banks=fc2title, fc2_orgs=fc2title, fc2_parties=fc2title, fc2_persons=fc2title, fc2_vendors=fc2title',
    'label field rename: the label column of every level follows the root''s');

SELECT is(pg_temp.fc_with_column(ARRAY['fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors'], 'fc2title')
          || ' | ' || pg_temp.fc_with_column(ARRAY['fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors'], 'label'),
    'fc2_banks, fc2_orgs, fc2_parties, fc2_persons, fc2_vendors | ',
    'label field rename: the root and every view show the column under its new name only');

SELECT is(pg_temp.fc_write($$UPDATE fc2_banks SET fc2title = 'B1-renamed' WHERE fc2title = 'B1'$$,
                           $$SELECT fc2title FROM fc2_parties WHERE fc2title = 'B1-renamed'$$),
    'B1-renamed',
    'label field rename: the label is written through the grandchild');

SELECT is(pg_temp.fc_write($$UPDATE fc2_parties SET fc2title = 'B1' WHERE fc2title = 'B1-renamed'$$,
                           $$SELECT fc2title FROM fc2_banks WHERE fc2title = 'B1'$$),
    'B1',
    'label field rename: and through the root');

SELECT * FROM pg_temp.fc_checks('after a rename of the root''s label field', 'fc2_');

UPDATE fields SET field_name = 'label' WHERE table_name = 'fc2_parties' AND field_name = 'fc2title';

SELECT is(
    (SELECT count(*)::INTEGER FROM entities
      WHERE table_name IN ('fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors')
        AND label_column <> 'label')
    + (SELECT count(*)::INTEGER FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'fc2\_%'
          AND a.attname = 'fc2title' AND NOT a.attisdropped),
    0,
    'label field renamed back: no label column and no column keeps the intermediate name');

SELECT * FROM pg_temp.fc_checks_on('after the label field is renamed back',
    'fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors', 'fc2title');

-- A derived entity's own label settings stay its root's.
SELECT throws_ok($$UPDATE entities SET label_column = 'vat' WHERE table_name = 'fc2_orgs'$$,
    '90242', NULL,
    'a child''s own label_column change is refused');

SELECT throws_ok($$UPDATE entities SET label_parent = 'vat' WHERE table_name = 'fc2_orgs'$$,
    '90242', NULL,
    'a child''s own label_parent change is refused');

SELECT throws_ok($$UPDATE entities SET label_column = 'bic' WHERE table_name = 'fc2_banks'$$,
    '90242', NULL,
    'a grandchild''s own label_column change is refused');

SELECT throws_ok($$UPDATE entities SET label_parent = 'bic' WHERE table_name = 'fc2_banks'$$,
    '90242', NULL,
    'a grandchild''s own label_parent change is refused');

-- The root's identity spine composes into every level's label.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc2_units', 'Unit', 'Units', 1);
INSERT INTO fc2_units (label) VALUES ('U1');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc2_parties', 'unit_id', 'Unit', 'reference', 'fc2_units', 'clear', 50);
UPDATE fc2_parties SET unit_id = (SELECT id FROM fc2_units WHERE label = 'U1') WHERE label = 'B1';
UPDATE entities SET label_parent = 'unit_id' WHERE table_name = 'fc2_parties';

SELECT is(pg_temp.value_of($$SELECT public._label(b) FROM fc2_banks b WHERE b.label = 'B1'$$), 'U1 › B1',
    'a label_parent on the root composes the grandchild''s label');

SELECT is(pg_temp.value_of($$SELECT public._label(v) FROM fc2_vendors v WHERE v.label = 'B1'$$), 'U1 › B1',
    'a label_parent on the root composes the extension''s label');

UPDATE entities SET label_parent = '' WHERE table_name = 'fc2_parties';

-- A direct label_column change on the root. It comes last in this part: until
-- it reaches every level, a write to a derived entity's row is refused.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc2_notes', 'Note', 'Notes', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc2_notes', 'bank_id', 'Bank', 'reference', 'fc2_banks', 'restrict', 30);
INSERT INTO fc2_notes (label, bank_id) SELECT 'N1', id FROM fc2_parties WHERE label = 'B1';
UPDATE fc2_parties SET city = 'Basel' WHERE label = 'B1';

UPDATE entities SET label_column = 'city' WHERE table_name = 'fc2_parties';

SELECT is(
    (SELECT string_agg(table_name || '=' || label_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fc2_parties', 'fc2_orgs', 'fc2_banks', 'fc2_persons', 'fc2_vendors')),
    'fc2_banks=city, fc2_orgs=city, fc2_parties=city, fc2_persons=city, fc2_vendors=city',
    'a direct label_column change on the root reaches every level');

SELECT is(pg_temp.value_of($$SELECT public._label(b) FROM fc2_banks b WHERE b.label = 'B1'$$), 'Basel',
    'after a direct label_column change on the root, the grandchild''s _label returns the new label column''s value');

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fc2_notes n WHERE n.label = 'N1'$$), 'Basel',
    'after a direct label_column change on the root, the label function of a plain entity referencing the grandchild returns the new label column''s value');

SELECT is((public.get_schema('fc2_banks')::jsonb) #>> '{table,label_column}', 'city',
    'get_schema of the grandchild names the new label column');

SELECT is((public.get_schema('fc2_notes')::jsonb) #>> '{properties,bank_id,reference_table_label_column}', 'city',
    'get_schema of the referencing entity names it as the referenced label column');

SELECT lives_ok($$UPDATE entities SET table_name = 'fc2_people' WHERE table_name = 'fc2_parties'$$,
    'after the change, the root can be renamed');

SELECT lives_ok(
    format($$UPDATE fields SET searchable = FALSE WHERE table_name = %L AND field_name = 'label'$$,
           (SELECT table_name FROM entities WHERE table_name IN ('fc2_parties', 'fc2_people'))),
    'after the change, a searchable change on the root goes through');

SELECT lives_ok(
    format($$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
             VALUES ('fc2_trusts', 'Trust', 'Trusts', 1, 'is_a', 'fcbtru', %L)$$,
           (SELECT table_name FROM entities WHERE table_name IN ('fc2_parties', 'fc2_people'))),
    'after the change, a new child of the root can be created');

SELECT is((SELECT label_column FROM entities WHERE table_name = 'fc2_trusts'), 'city',
    'the new child takes the root''s new label column');

-- =====================================================
-- PART 3: the key column
-- =====================================================
-- id_column names the physical key. Changing the row runs no DDL, so a
-- changed id_column would describe a column that does not exist; it is set
-- when an entity is created, for every key type.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc3_', 'fcc');
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc3_plain', 'Plain', 'Plains', 1);

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fc3_parties'$$), '90253',
    'id_column cannot change on a family root');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fc3_orgs'$$), '90253',
    'id_column cannot change on an is_a entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fc3_vendors'$$), '90253',
    'id_column cannot change on a has_a entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'key' WHERE table_name = 'fc3_plain'$$), '90253',
    'id_column cannot change on a plain entity');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_column = 'id' WHERE table_name = 'fc3_parties'$$), '00000',
    'an update that writes the same id_column back passes');

SELECT is(
    (SELECT string_agg(e.table_name || '=' || e.id_column || '/' || f.field_name || '/' || a.attname,
                       ', ' ORDER BY e.table_name COLLATE "C")
       FROM entities e
       JOIN fields f ON f.table_name = e.table_name AND f.ctype = 'id'
       JOIN pg_constraint k ON k.conrelid = to_regclass(format('public.%I', dd_relation(e.table_name))) AND k.contype = 'p'
       JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
      WHERE e.table_name IN ('fc3_parties', 'fc3_orgs', 'fc3_vendors', 'fc3_plain')),
    'fc3_orgs=id/id/id, fc3_parties=id/id/id, fc3_plain=id/id/id, fc3_vendors=id/id/id',
    'id_column, the id field row and the physical key are unchanged');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fc3_parties', 'fc3extra', 'Extra', 'text', 50)$$,
    'a root field add still works');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fc3_plain', 'fc3extra', 'Extra', 'text', 50)$$,
    'a field add on the plain entity still works');

-- A root whose key column is not id: every level inherits it.
SELECT pg_temp.fc_build('fc3k_', 'fcck', 'pid');

SELECT is(
    (SELECT string_agg(table_name || '=' || id_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fc3k_parties', 'fc3k_orgs', 'fc3k_banks', 'fc3k_persons', 'fc3k_vendors')),
    'fc3k_banks=pid, fc3k_orgs=pid, fc3k_parties=pid, fc3k_persons=pid, fc3k_vendors=pid',
    'a root keyed by pid: every level inherits its key column');

SELECT is(
    (SELECT string_agg(c.relname || ':' || a.attname, ', ' ORDER BY c.relname)
       FROM pg_attribute a
       JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fc3k_orgs', 'fc3k_orgs_ext', 'fc3k_banks', 'fc3k_banks_ext',
                          'fc3k_persons', 'fc3k_persons_ext', 'fc3k_vendors', 'fc3k_vendors_ext')
        AND a.attnum = 1),
    'fc3k_banks:pid, fc3k_banks_ext:pid, fc3k_orgs:pid, fc3k_orgs_ext:pid, fc3k_persons:pid, fc3k_persons_ext:pid, fc3k_vendors:pid, fc3k_vendors_ext:pid',
    'a root keyed by pid: every view and every part is keyed by pid');

SELECT * FROM pg_temp.fc_checks('a family keyed by pid', 'fc3k_');

SELECT lives_ok($$DELETE FROM fc3k_parties WHERE label = 'R1'$$,
    'a root keyed by pid: a delete through the root reaches the subtype record');

SELECT is((SELECT count(*)::INTEGER FROM fc3k_persons_ext), 0,
    'a root keyed by pid: and removes its part');

-- =====================================================
-- PART 4: entity-level changes
-- =====================================================
-- Labels, renames and prefixes of the members, a new subtype under a level
-- that has records, the root's order column, and entities.is_child, which the
-- application reads to hide a child from the navigation.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc4_', 'fcd');

-- The root's labels are its own.
UPDATE entities SET singular_label = 'Counterparty', plural_label = 'Counterparties', description = 'Anyone we deal with'
 WHERE table_name = 'fc4_parties';

SELECT is(obj_description('public.fc4_parties'::regclass, 'pg_class'), E'Counterparties\n\nAnyone we deal with',
    'root labels: the root table''s comment follows');

SELECT is(((public.get_schema('fc4_parties')::jsonb) ->> 'title') || ' / ' || ((public.get_schema('fc4_parties')::jsonb) ->> 'description'),
    'Counterparty / Anyone we deal with',
    'root labels: so does the root''s get_schema');

SELECT is(
    (SELECT string_agg(c.relname || '=' || coalesce(obj_description(c.oid, 'pg_class'), ''), ', ' ORDER BY c.relname)
       FROM pg_class c
      WHERE c.relnamespace = 'public'::regnamespace
        AND c.relname IN ('fc4_orgs', 'fc4_banks', 'fc4_persons', 'fc4_vendors')),
    'fc4_banks=Banks, fc4_orgs=Organizations, fc4_persons=Persons, fc4_vendors=Vendors',
    'root labels: every view keeps its own comment');

SELECT is(
    (SELECT string_agg(public.get_schema(n)::jsonb ->> 'title', ', ' ORDER BY o)
       FROM unnest(ARRAY['fc4_orgs', 'fc4_banks', 'fc4_persons', 'fc4_vendors']) WITH ORDINALITY AS u(n, o)),
    'Organization, Bank, Person, Vendor',
    'root labels: every level''s get_schema keeps its own title');

UPDATE entities SET plural_label = 'Bank Branches', description = 'Branches that hold accounts'
 WHERE table_name = 'fc4_banks';

SELECT is(obj_description('public.fc4_banks'::regclass, 'pg_class'), E'Bank Branches\n\nBranches that hold accounts',
    'a child''s own labels reach its view''s comment');

-- A root rename.
UPDATE entities SET table_name = 'fc4_people' WHERE table_name = 'fc4_parties';

SELECT is(
    (SELECT string_agg(table_name || '>' || id_refentity, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('fc4_orgs', 'fc4_banks', 'fc4_persons', 'fc4_vendors')),
    'fc4_banks>fc4_orgs, fc4_orgs>fc4_people, fc4_persons>fc4_people, fc4_vendors>fc4_people',
    'root rename: the base of every child follows');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fc4_parties')
    AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fc4_people')
    AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fc4_people') AND tgname = 'a_is_a_dispatch'),
    'root rename: the dispatch routine is rebuilt under the new name');

SELECT is(
    (SELECT count(*)::INTEGER FROM (
        SELECT relname::TEXT FROM pg_class WHERE relname LIKE '%fc4\_parties%'
        UNION ALL SELECT proname::TEXT FROM pg_proc WHERE proname LIKE '%fc4\_parties%' OR prosrc LIKE '%fc4\_parties%'
        UNION ALL SELECT tgname::TEXT FROM pg_trigger WHERE tgname LIKE '%fc4\_parties%'
        UNION ALL SELECT polname::TEXT FROM pg_policy WHERE polname LIKE '%fc4\_parties%'
        UNION ALL SELECT conname::TEXT FROM pg_constraint WHERE conname LIKE '%fc4\_parties%') s),
    0,
    'root rename: nothing is left under the old name, generated routine bodies included');

SELECT * FROM pg_temp.fc_checks_on('after a root rename',
    'fc4_people', 'fc4_orgs', 'fc4_banks', 'fc4_persons', 'fc4_vendors', 'fc4_parties');

-- A has_a rename.
UPDATE entities SET table_name = 'fc4_suppliers' WHERE table_name = 'fc4_vendors';

SELECT is(pg_temp.fc_args('fc4_people', 'a_has_a_guard'), 'id,fc4_suppliers,',
    'has_a rename: the base''s delete guard names the extension under its new name');

SELECT throws_ok($$DELETE FROM fc4_people WHERE label = 'B1'$$,
    '90251', NULL,
    'has_a rename: a base record with an extension still cannot be deleted');

SELECT * FROM pg_temp.fc_checks_on('after a has_a rename',
    'fc4_people', 'fc4_orgs', 'fc4_banks', 'fc4_persons', 'fc4_suppliers', 'fc4_vendors');

-- A root prefix change after a has_a entity exists: the extension's write
-- routine mints and checks the root's ids.
UPDATE entities SET id_prefix = 'fcdpnew' WHERE table_name = 'fc4_people';
INSERT INTO fc4_suppliers (label, terms) VALUES ('S2', 'net60');

SELECT is((SELECT common.typeid_prefix(id) FROM fc4_people WHERE label = 'S2'), 'fcdpnew',
    'root prefix change: a base record created through the extension takes the new prefix');

SELECT throws_ok($$INSERT INTO fc4_suppliers (id, label) VALUES ('fcdpty_01h455vb4pex5vsknk084sn02q', 'S3')$$,
    '90237', NULL,
    'root prefix change: an id with the former prefix is refused');

-- A new subtype under a middle level that has records and a child.
SELECT pg_temp.fc_build('fc4n_', 'fcdn');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('fc4n_insurers', 'Insurer', 'Insurers', 1, 'is_a', 'fcdnins', 'fc4n_orgs', 'nwind:view', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc4n_insurers', 'policy', 'Policy', 'text', 30),
       ('fc4n_insurers', 'itag', 'Insurer Tag', 'text', 40);
UPDATE entities SET computed_fields = '[{"name": "itag", "jsonlogic": {"cat": ["I:", {"var": "city"}]}}]'::jsonb
 WHERE table_name = 'fc4n_insurers';

SELECT ok(pg_temp.fc_args('fc4n_parties', 'typeid_assign') LIKE '%,fcdnins,%',
    'new subtype under a middle level: the root''s typeid_assign accepts its prefix');

SELECT lives_ok($$INSERT INTO fc4n_insurers (label, city, vat, policy) VALUES ('I1', 'Ivrea', 'IT9', 'POL1')$$,
    'new subtype under a middle level: records are created through it');

SELECT is(pg_temp.fc_write($$UPDATE fc4n_parties SET city = 'Imola' WHERE label = 'I1'$$,
                           $$SELECT itag FROM fc4n_insurers WHERE label = 'I1'$$),
    'I:Imola',
    'new subtype under a middle level: the root''s dispatch routes to it');

SELECT is(pg_temp.fc_write($$UPDATE fc4n_orgs SET city = 'Ischia' WHERE label = 'I1'$$,
                           $$SELECT itag FROM fc4n_insurers WHERE label = 'I1'$$),
    'I:Ischia',
    'new subtype under a middle level: so does the middle level''s view');

SELECT is(
    (SELECT string_agg(label || ':' || common.typeid_prefix(id) || ':' || vat, ', ' ORDER BY label COLLATE "C") FROM fc4n_orgs),
    'B1:fcdnbnk:CH1, I1:fcdnins:IT9, O1:fcdnorg:NO1',
    'new subtype under a middle level: the records already there are untouched');

SELECT * FROM pg_temp.fc_checks('after a new subtype under a middle level', 'fc4n_');

-- The root's order column is no field: it is in no view, and a record created
-- through a subtype still gets a position.
SELECT lives_ok($$UPDATE entities SET order_column = 'fc4pos' WHERE table_name = 'fc4n_parties'$$,
    'a root with subtypes may take an order column');

SELECT is(pg_temp.fc_with_column(ARRAY['fc4n_orgs', 'fc4n_banks', 'fc4n_persons', 'fc4n_vendors', 'fc4n_insurers'], 'fc4pos'),
    '',
    'the root''s order column is in no view');

INSERT INTO fc4n_banks (label, city, vat, bic) VALUES ('B9', 'Bari', 'IT8', 'BIC9');

SELECT is(pg_temp.value_of($$SELECT (fc4pos > 0)::TEXT FROM fc4n_parties WHERE label = 'B9'$$), 'true',
    'a record created through a subtype gets a position in the root''s order column');

-- A prefix that rows of the root still carry is not free for a new subtype:
-- those rows would be taken for records of that subtype.
SELECT pg_temp.fc_build('fc4p_', 'fcdp');
UPDATE entities SET id_prefix = 'fcdpptytwo' WHERE table_name = 'fc4p_parties';

SELECT is(pg_temp.sqlstate_of(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
      VALUES ('fc4p_clubs', 'Club', 'Clubs', 1, 'is_a', 'fcdppty', 'fc4p_parties')$$),
    '90254',
    'a new subtype cannot take a prefix that rows of its root still carry');

SELECT is(pg_temp.fc_write($$UPDATE fc4p_parties SET city = 'Reached' WHERE label = 'P1'$$,
                           $$SELECT city FROM fc4p_parties WHERE label = 'P1'$$),
    'Reached',
    'the root''s rows under its former prefix are still updated through the root');

SELECT lives_ok($$DELETE FROM fc4p_parties WHERE label = 'P1'$$,
    'the root''s rows under its former prefix are still deleted through the root');

SELECT is((SELECT count(*)::INTEGER FROM fc4p_parties WHERE label = 'P1'), 0,
    'the delete removed the row');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fc4p_misc', 'Misc', 'Miscs', 1, 'typeid', 'fcdpfree');
UPDATE entities SET id_prefix = 'fcdpfreetwo' WHERE table_name = 'fc4p_misc';

SELECT lives_ok(
    $$INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
      VALUES ('fc4p_clubs', 'Club', 'Clubs', 1, 'is_a', 'fcdpfree', 'fc4p_parties')$$,
    'a released prefix that no row of the root carries can be taken by a new subtype');

-- A root row whose id names a subtype that has no part for it. Only the owner
-- can make one, by writing a part table past its guard.
SELECT pg_temp.fc_build('fc4m_', 'fcdm');
INSERT INTO fc4m_banks (label, city, vat, bic) VALUES ('B2', 'Bonn', 'DE2', 'BIC2');

RESET ROLE;
ALTER TABLE public.fc4m_banks_ext DISABLE TRIGGER a_ext_write_guard;
DELETE FROM public.fc4m_banks_ext WHERE id = (SELECT id FROM public.fc4m_parties WHERE label = 'B2');
ALTER TABLE public.fc4m_banks_ext ENABLE TRIGGER a_ext_write_guard;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$UPDATE fc4m_parties SET city = 'Nowhere' WHERE label = 'B2'$$), '90255',
    'an update through the root of a record whose subtype part is missing is refused, not skipped');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM fc4m_parties WHERE label = 'B2'$$), '90255',
    'a delete through the root of a record whose subtype part is missing is refused, not skipped');

-- A subtype record the caller cannot read is skipped as before.
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'fc4m_banks';
SELECT authenticate_as('user2');

SELECT lives_ok($$UPDATE fc4m_parties SET city = 'Ulm' WHERE label = 'B1'$$,
    'an update through the root of a subtype record the caller cannot read raises nothing');

SELECT authenticate_as('user3');

SELECT is((SELECT city FROM fc4m_parties WHERE label = 'B1'), 'Bern',
    'the record the caller cannot read is skipped');

SELECT is(pg_temp.fc_write($$UPDATE fc4m_parties SET city = 'Bremen' WHERE label = 'B1'$$,
                           $$SELECT city FROM fc4m_banks WHERE label = 'B1'$$),
    'Bremen',
    'an administrator updates it');

-- is_child follows the family: a level is a child when it or a level above
-- it has a parent field.
SELECT pg_temp.fc_build('fc4c_', 'fcdc');
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc4c_groups', 'Group', 'Groups', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc4c_parties', 'group_id', 'Group', 'parent', 'fc4c_groups', 'cascade', 50);

SELECT is(pg_temp.fc_is_child('fc4c_'),
    'fc4c_banks=true, fc4c_orgs=true, fc4c_parties=true, fc4c_persons=true, fc4c_vendors=true',
    'is_child: a parent field on the root makes every level a child');

UPDATE fields SET format = 'reference' WHERE table_name = 'fc4c_parties' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child('fc4c_'),
    'fc4c_banks=false, fc4c_orgs=false, fc4c_parties=false, fc4c_persons=false, fc4c_vendors=false',
    'is_child: changing it to a plain reference clears every level');

UPDATE fields SET format = 'parent' WHERE table_name = 'fc4c_parties' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child('fc4c_'),
    'fc4c_banks=true, fc4c_orgs=true, fc4c_parties=true, fc4c_persons=true, fc4c_vendors=true',
    'is_child: changing it back to parent sets every level again');

DELETE FROM fields WHERE table_name = 'fc4c_parties' AND field_name = 'group_id';

SELECT is(pg_temp.fc_is_child('fc4c_'),
    'fc4c_banks=false, fc4c_orgs=false, fc4c_parties=false, fc4c_persons=false, fc4c_vendors=false',
    'is_child: deleting it clears every level');

INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc4c_orgs', 'org_group_id', 'Organization Group', 'parent', 'fc4c_groups', 'restrict', 50);

SELECT is(pg_temp.fc_is_child('fc4c_'),
    'fc4c_banks=true, fc4c_orgs=true, fc4c_parties=false, fc4c_persons=false, fc4c_vendors=false',
    'is_child: a parent field on a middle level makes it and the level below it children, not the root or the other branch');

DELETE FROM fields WHERE table_name = 'fc4c_orgs' AND field_name = 'org_group_id';
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc4c_parties', 'group_id', 'Group', 'parent', 'fc4c_groups', 'cascade', 50);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('fc4c_clubs', 'Club', 'Clubs', 1, 'is_a', 'fcdcclb', 'fc4c_parties');

SELECT is((SELECT is_child FROM entities WHERE table_name = 'fc4c_clubs'), TRUE,
    'is_child: a subtype created under a root that is a child is created as a child');

-- =====================================================
-- PART 5: rules and permissions
-- =====================================================
-- A level's rules and permissions apply to every record stored in it, so they
-- reach the levels below it and the writes carried down from the root.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc5_', 'fce');

-- Rules added to a middle level after its child exists.
UPDATE entities
   SET validation_rules = '[{"code": "99501", "message": "an organization cannot be in Nowhere",
                             "jsonlogic": {"!=": [{"var": "city"}, "Nowhere"]}}]'::jsonb
 WHERE table_name = 'fc5_orgs';

SELECT throws_ok($$UPDATE fc5_banks SET city = 'Nowhere' WHERE label = 'B1'$$,
    '99501', NULL,
    'a rule added to a middle level is enforced through the level below it');

SELECT throws_ok($$UPDATE fc5_parties SET city = 'Nowhere' WHERE label = 'B1'$$,
    '99501', NULL,
    'a rule added to a middle level is enforced through the root');

SELECT lives_ok($$UPDATE fc5_parties SET city = 'Nowhere' WHERE label = 'P1'$$,
    'a rule of a middle level does not apply to a record of the root''s own type');

UPDATE entities SET validation_rules = '[]'::jsonb WHERE table_name = 'fc5_orgs';

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'record_rules_fc5_orgs'),
    'clearing a middle level''s rules drops its rule routine');

SELECT lives_ok($$UPDATE fc5_banks SET city = 'Nowhere' WHERE label = 'B1'$$,
    'with the rules cleared, a write through the level below still works');

SELECT lives_ok($$UPDATE fc5_parties SET city = 'Bern' WHERE label = 'B1'$$,
    'with the rules cleared, a write through the root still works');

-- A middle level's view permission gates the levels below it.
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'fc5_orgs';
SELECT authenticate_as('user2');

SELECT is((SELECT count(*)::INTEGER FROM fc5_banks), 0,
    'a middle level readable by administrators only hides the level below it from others');

SELECT throws_ok($$SELECT public.get_schema('fc5_banks')$$,
    '42P01', NULL,
    'a middle level readable by administrators only hides the schema of the level below it from others');

SELECT authenticate_as('user3');

SELECT is((SELECT count(*)::INTEGER FROM fc5_banks), 1,
    'an administrator still reads it');

SELECT lives_ok($$SELECT public.get_schema('fc5_banks')$$,
    'an administrator still reads its schema');

UPDATE entities SET view_permission = 'nwind:view' WHERE table_name = 'fc5_orgs';

-- A select_rule on the root filters every view and the writes through the
-- root.
UPDATE fc5_parties SET city = 'Hidden' WHERE label = 'B1';
UPDATE entities
   SET select_rule = '{"or": [{"has_permission": "admin"}, {"!=": [{"var": "city"}, "Hidden"]}]}'::jsonb
 WHERE table_name = 'fc5_parties';
SELECT authenticate_as('user2');

SELECT is(
    (SELECT count(*)::INTEGER FROM fc5_orgs WHERE label = 'B1')
    + (SELECT count(*)::INTEGER FROM fc5_banks WHERE label = 'B1')
    + (SELECT count(*)::INTEGER FROM fc5_vendors WHERE label = 'B1'),
    0,
    'a select_rule on the root hides the record in every view of the family');

UPDATE fc5_parties SET city = 'Seen' WHERE label = 'B1';
SELECT authenticate_as('user3');

SELECT is((SELECT city FROM fc5_parties WHERE label = 'B1'), 'Hidden',
    'a select_rule on the root keeps a write through the root off the record');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'fc5_parties';

-- A derived entity's select_rule reads its base, so a rename of the base has
-- to reach it.
UPDATE entities SET select_rule = '{"!=": [{"var": "city"}, "never"]}'::jsonb
 WHERE table_name IN ('fc5_orgs', 'fc5_vendors');
UPDATE entities SET table_name = 'fc5_people' WHERE table_name = 'fc5_parties';
SELECT authenticate_as('user2');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fc5_orgs$$), '2',
    'after a root rename, a child with a select_rule is still readable');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fc5_vendors$$), '1',
    'after a root rename, an extension with a select_rule is still readable');

SELECT authenticate_as('user3');

SELECT is(
    (SELECT string_agg(p.proname::TEXT, ', ' ORDER BY p.proname) FROM pg_proc p
      WHERE p.proname IN ('select_rule_fc5_orgs', 'select_rule_fc5_vendors') AND p.pronargs = 2
        AND p.prosrc LIKE '%fc5\_people%' AND p.prosrc NOT LIKE '%fc5\_parties%'),
    'select_rule_fc5_orgs, select_rule_fc5_vendors',
    'after a root rename, their select_rule routines read the root under its new name');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name IN ('fc5_orgs', 'fc5_vendors');
UPDATE entities SET select_rule = '{"!=": [{"var": "vat"}, "never"]}'::jsonb WHERE table_name = 'fc5_banks';
UPDATE entities SET table_name = 'fc5_companies' WHERE table_name = 'fc5_orgs';
SELECT authenticate_as('user2');

SELECT is(pg_temp.value_of($$SELECT count(*) FROM fc5_banks$$), '1',
    'after a middle level''s rename, the grandchild with a select_rule is still readable');

SELECT authenticate_as('user3');

SELECT is(
    (SELECT count(*)::INTEGER FROM pg_proc p
      WHERE p.proname = 'select_rule_fc5_banks' AND p.pronargs = 2
        AND p.prosrc LIKE '%fc5\_companies%' AND p.prosrc NOT LIKE '%fc5\_orgs%'),
    1,
    'after a middle level''s rename, the grandchild''s select_rule routine reads it under its new name');

-- A queue mapped on the root reports changes to root rows: a subtype record's
-- root row is created, changed or deleted with it, its other parts are not.
SELECT pg_temp.fc_build('fc5q_', 'fceq');
INSERT INTO queues (queue_name) VALUES ('fc5q_events');
INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
SELECT id, 'party change', 'fc5q_parties', 'change' FROM queues WHERE queue_name = 'fc5q_events';

INSERT INTO fc5q_banks (label, city, vat, bic) VALUES ('B7', 'Brno', 'CZ7', 'BIC7');

SELECT is(pg_temp.fc_messages('fc5q_events', 'fc5q_parties'), 1,
    'a queue on the root: creating a subtype record sends one message');

UPDATE fc5q_banks SET bic = 'BIC8' WHERE label = 'B7';

SELECT is(pg_temp.fc_messages('fc5q_events', 'fc5q_parties'), 1,
    'a queue on the root: an update of subtype fields only sends none');

UPDATE fc5q_banks SET city = 'Brugge' WHERE label = 'B7';

SELECT is(pg_temp.fc_messages('fc5q_events', 'fc5q_parties'), 2,
    'a queue on the root: an update of a root field sends one');

DELETE FROM fc5q_banks WHERE label = 'B7';

SELECT is(pg_temp.fc_messages('fc5q_events', 'fc5q_parties'), 3,
    'a queue on the root: deleting the subtype record sends one');

SELECT throws_ok(
    $$INSERT INTO queue_table_events (queue_id, event_name, table_name, event_handler)
      SELECT id, 'bank change', 'fc5q_banks', 'change' FROM queues WHERE queue_name = 'fc5q_events'$$,
    '90249', NULL,
    'a queue cannot be mapped on the subtype itself');

-- =====================================================
-- PART 6: an is_a and a has_a entity on one base record
-- =====================================================
-- B1 is a bank and has a vendor extension. A root field written through the
-- extension is a change of the bank record, so the rules and permissions of
-- every level of the bank apply to it.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc6_', 'fcf');

SELECT is((SELECT label || '/' || city || '/' || terms FROM fc6_vendors), 'B1/Bern/net30',
    'the extension of a subtype record shows the root''s fields');

SELECT throws_ok($$INSERT INTO fc6_vendors (id, city, terms) SELECT id, 'Elsewhere', 'net5' FROM fc6_parties WHERE label = 'O1'$$,
    '90246', NULL,
    'an attach that brings a root value other than the stored one is refused');

UPDATE fc6_parties SET city = 'Basel' WHERE label = 'B1';

SELECT is((SELECT v.city || '/' || b.city || '/' || b.tag FROM fc6_vendors v JOIN fc6_banks b ON b.id = v.id),
    'Basel/Basel/T:Basel',
    'a root field change reaches the extension and the subtype in the same statement');

UPDATE fc6_vendors SET city = 'Vaduz' WHERE label = 'B1';

SELECT is((SELECT city || '/' || tag FROM fc6_banks WHERE label = 'B1'), 'Vaduz/T:Vaduz',
    'a root field written through the extension runs the rules of the record''s own type');

UPDATE entities
   SET validation_rules = '[{"code": "99601", "message": "an organization cannot be in Forbidden",
                             "jsonlogic": {"!=": [{"var": "city"}, "Forbidden"]}}]'::jsonb
 WHERE table_name = 'fc6_orgs';

SELECT is(pg_temp.sqlstate_of($$UPDATE fc6_vendors SET city = 'Forbidden' WHERE label = 'B1'$$), '99601',
    'a root field written through the extension runs the rules of the levels in between');

SELECT authenticate_as('user2');

SELECT lives_ok($$UPDATE fc6_vendors SET city = 'Ulm', terms = 'net1' WHERE label = 'B1'$$,
    'a caller who may write the extension and the root but not the subtype: the update raises nothing');

SELECT authenticate_as('user3');

SELECT is((SELECT p.city || '/' || v.terms FROM fc6_parties p JOIN fc6_vendors v ON v.id = p.id WHERE p.label = 'B1'),
    'Vaduz/net30',
    'that caller''s update skips the record: neither the root nor the extension changes');

SELECT is(pg_temp.fc_write($$UPDATE fc6_vendors SET city = 'Uppsala', terms = 'net2' WHERE label = 'B1'$$,
                           $$SELECT p.city || '/' || v.terms FROM fc6_parties p JOIN fc6_vendors v ON v.id = p.id WHERE p.label = 'B1'$$),
    'Uppsala/net2',
    'an administrator''s same update is written');

INSERT INTO fc6_vendors (id, terms) SELECT id, 'net10' FROM fc6_parties WHERE label = 'P1';

SELECT is(pg_temp.fc_write($$UPDATE fc6_vendors SET city = 'Pisa' WHERE label = 'P1'$$,
                           $$SELECT city FROM fc6_parties WHERE label = 'P1'$$),
    'Pisa',
    'the extension of a record of the root''s own type writes the root''s fields itself');

INSERT INTO fc_marks
SELECT 'fc6 row positions',
       (SELECT ctid::TEXT FROM fc6_parties WHERE label = 'B1')
       || (SELECT x.ctid::TEXT FROM fc6_orgs_ext x JOIN fc6_parties p ON p.id = x.id WHERE p.label = 'B1')
       || (SELECT x.ctid::TEXT FROM fc6_banks_ext x JOIN fc6_parties p ON p.id = x.id WHERE p.label = 'B1');
UPDATE fc6_vendors SET terms = 'net90' WHERE label = 'B1';

SELECT is(
    (SELECT ctid::TEXT FROM fc6_parties WHERE label = 'B1')
    || (SELECT x.ctid::TEXT FROM fc6_orgs_ext x JOIN fc6_parties p ON p.id = x.id WHERE p.label = 'B1')
    || (SELECT x.ctid::TEXT FROM fc6_banks_ext x JOIN fc6_parties p ON p.id = x.id WHERE p.label = 'B1'),
    (SELECT v FROM fc_marks WHERE k = 'fc6 row positions'),
    'an update of the extension''s own fields writes neither the root nor the subtype''s parts');

-- Deleting the bank record.
SELECT throws_ok($$DELETE FROM fc6_banks WHERE label = 'B1'$$,
    '90251', NULL,
    'a subtype record with an extension cannot be deleted through its own view');

SELECT throws_ok($$DELETE FROM fc6_parties WHERE label = 'B1'$$,
    '90251', NULL,
    'a subtype record with an extension cannot be deleted through the root');

DELETE FROM fc6_vendors WHERE label = 'B1';
UPDATE entities
   SET validation_rules = '[{"code": "99603", "message": "a kept party cannot be deleted",
                             "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                        {"==": [{"var": "city"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fc6_parties';
UPDATE entities
   SET validation_rules = validation_rules
                          || '[{"code": "99604", "message": "a kept organization cannot be deleted",
                                "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                           {"==": [{"var": "vat"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fc6_orgs';
UPDATE entities
   SET validation_rules = '[{"code": "99605", "message": "a kept bank cannot be deleted",
                             "jsonlogic": {"!": {"and": [{"==": [{"var": "$mode"}, "delete"]},
                                                        {"==": [{"var": "bic"}, "keep"]}]}}}]'::jsonb
 WHERE table_name = 'fc6_banks';

UPDATE fc6_banks SET bic = 'keep' WHERE label = 'B1';

SELECT throws_ok($$DELETE FROM fc6_parties WHERE label = 'B1'$$,
    '99605', NULL,
    'once detached, a delete through the root runs the subtype''s delete rules');

UPDATE fc6_banks SET bic = 'BIC1', vat = 'keep' WHERE label = 'B1';

SELECT throws_ok($$DELETE FROM fc6_parties WHERE label = 'B1'$$,
    '99604', NULL,
    'once detached, a delete through the root runs the middle level''s delete rules');

UPDATE fc6_banks SET vat = 'CH1', city = 'keep' WHERE label = 'B1';

SELECT throws_ok($$DELETE FROM fc6_banks WHERE label = 'B1'$$,
    '99603', NULL,
    'once detached, a delete through the subtype''s view runs the root''s own rule trigger');

UPDATE fc6_banks SET city = 'Bern' WHERE label = 'B1';

SELECT lives_ok($$DELETE FROM fc6_banks WHERE label = 'B1'$$,
    'with no rule refusing, the subtype record is deleted');

SELECT is(
    (SELECT count(*)::INTEGER FROM fc6_parties WHERE label = 'B1')
    + (SELECT count(*)::INTEGER FROM fc6_orgs_ext x WHERE NOT EXISTS (SELECT 1 FROM fc6_parties p WHERE p.id = x.id))
    + (SELECT count(*)::INTEGER FROM fc6_banks_ext x WHERE NOT EXISTS (SELECT 1 FROM fc6_parties p WHERE p.id = x.id)),
    0,
    'the delete removed every part of the record');

-- =====================================================
-- PART 7: records
-- =====================================================
-- An attach through an extension tells a column the caller left out, which
-- holds the view's default, from a value the caller brought by comparing with
-- the column default written into the write routine. A changed default has to
-- reach that routine.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc7_', 'fcg');

UPDATE fields SET default_value = 'Paris' WHERE table_name = 'fc7_parties' AND field_name = 'city';

SELECT lives_ok($$INSERT INTO fc7_vendors (id, terms) SELECT id, 'net15' FROM fc7_parties WHERE label = 'O1'$$,
    'after a root default change, an attach that leaves the field out is accepted');

SELECT is((SELECT city || '/' || terms FROM fc7_vendors WHERE label = 'O1'), 'Oslo/net15',
    'after a root default change, the attach keeps the stored value');

-- =====================================================
-- PART 8: references from other entities
-- =====================================================
-- A reference to a subtype points at its part and reads its label through the
-- subtype's view, both of which a rebuild or a rename replaces.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc8_', 'fch');
INSERT INTO fc8_banks (label, city, vat, bic) VALUES ('B2', 'Basel', 'CH2', 'BIC2');
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('fc8_notes', 'Note', 'Notes', 1),
       ('fc8_memos', 'Memo', 'Memos', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc8_notes', 'bank_id', 'Bank', 'reference', 'fc8_banks', 'cascade', 30),
       ('fc8_memos', 'bank_id', 'Bank', 'reference', 'fc8_banks', 'clear', 30);
INSERT INTO fc8_notes (label, bank_id) SELECT 'N' || right(label, 1), id FROM fc8_parties WHERE label IN ('B1', 'B2');
INSERT INTO fc8_memos (label, bank_id) SELECT 'M' || right(label, 1), id FROM fc8_parties WHERE label IN ('B1', 'B2');

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fc8_notes n WHERE n.label = 'N1'$$), 'B1',
    'a reference to a subtype resolves its label');

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc8_parties', 'fc8extra', 'Extra', 'text', 50);

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fc8_notes n WHERE n.label = 'N1'$$), 'B1',
    'the label still resolves after a family rebuild replaced the subtype''s view and its _label');

UPDATE entities SET table_name = 'fc8_branches' WHERE table_name = 'fc8_banks';

SELECT is(
    (SELECT string_agg(c.conname || '->' || c.confrelid::regclass::TEXT, ', ' ORDER BY c.conname)
       FROM pg_constraint c WHERE c.conname IN ('fc8_notes_bank_id_fkey', 'fc8_memos_bank_id_fkey')),
    'fc8_memos_bank_id_fkey->fc8_branches_ext, fc8_notes_bank_id_fkey->fc8_branches_ext',
    'a subtype rename: the foreign keys to it target its renamed part');

SELECT is(pg_temp.value_of($$SELECT public.bank_id_label(n) FROM fc8_notes n WHERE n.label = 'N1'$$), 'B1',
    'a subtype rename: the label still resolves');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bank_id_label' AND pronargs = 1
               AND proargtypes[0] = to_regtype('public.fc8_notes')::oid
               AND prosrc LIKE '%fc8\_branches%' AND prosrc NOT LIKE '%fc8\_banks%'),
    'a subtype rename: the label function is rebuilt to read the subtype under its new name');

DELETE FROM fc8_parties WHERE label = 'B2';

SELECT is(
    (SELECT count(*) FROM fc8_notes WHERE label = 'N2')::TEXT || '/'
    || (SELECT coalesce(bank_id::TEXT, 'cleared') FROM fc8_memos WHERE label = 'M2'),
    '0/cleared',
    'a delete through the root runs the cascading and the clearing references to the subtype');

-- =====================================================
-- PART 9: refused changes and the DDL audit
-- =====================================================
-- A refusal is raised before the family is rebuilt, so the family is left
-- exactly as it was. A change that is carried out logs its own DDL, not the
-- rebuild that follows from it.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc9_', 'fci');

INSERT INTO fc_marks VALUES ('fc9 before clash', pg_temp.fc_snapshot('fc9_parties'));

SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                   VALUES ('fc9_parties', 'bic', 'BIC', 'text', 60)$$,
    '90243', NULL,
    'a root field whose name a subtype uses is refused');

SELECT is(pg_temp.fc_snapshot('fc9_parties'), (SELECT v FROM fc_marks WHERE k = 'fc9 before clash'),
    'the refused field leaves every view, routine and trigger of the family as it was');

INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc9_plain', 'Plain', 'Plains', 1);
INSERT INTO fc_marks SELECT 'fc9 start', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fc9_plain', 'pnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'fc9 plain', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fc9_parties', 'rnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'fc9 root', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fc9_orgs', 'onote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'fc9 org', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES ('fc9_banks', 'bnote', 'Note', 'text', 40);
INSERT INTO fc_marks SELECT 'fc9 bank', coalesce(max(id), 0)::TEXT FROM audit_ddl_logs;

SELECT is(pg_temp.fc_ddl_log('fc9 plain', 'fc9 root', 'fc9_parties'),
    pg_temp.fc_ddl_log('fc9 start', 'fc9 plain', 'fc9_plain'),
    'a root field add logs its own DDL only, not the rebuild of the views and routines of three levels');

SELECT is(pg_temp.fc_ddl_log('fc9 root', 'fc9 org', 'fc9_orgs_ext'),
    pg_temp.fc_ddl_log('fc9 start', 'fc9 plain', 'fc9_plain'),
    'a middle-level field add logs its own DDL only');

SELECT is(pg_temp.fc_ddl_log('fc9 org', 'fc9 bank', 'fc9_banks_ext'),
    pg_temp.fc_ddl_log('fc9 start', 'fc9 plain', 'fc9_plain'),
    'a grandchild field add logs its own DDL only');

-- =====================================================
-- PART 10: dropping family entities
-- =====================================================
-- A family is taken apart from the bottom: an entity goes once nothing is
-- based on it and its records are gone, and the rest of the family is rebuilt
-- without it. A refused delete drops nothing.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc10_', 'fcj');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10_orgs'$$,
    '90248', NULL,
    'a middle level with a child cannot be deleted');

SELECT ok(pg_temp.fc_intact('fc10_'),
    'the refused delete of the middle level dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10_vendors'$$,
    '90247', NULL,
    'an extension with records cannot be deleted');

SELECT ok(pg_temp.fc_intact('fc10_'),
    'the refused delete of the extension dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10_parties'$$,
    '90248', NULL,
    'a root with records and dependents of both kinds is refused for its dependents first');

SELECT ok(pg_temp.fc_intact('fc10_'),
    'the refused delete of the root dropped nothing');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fc10_accounts', 'Account', 'Accounts', 1, 'typeid', 'fcjacc');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity)
VALUES ('fc10_acctinfo', 'Account Info', 'Account Infos', 1, 'has_a', 'fc10_accounts');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10_accounts'$$,
    '90248', NULL,
    'a base whose only dependents are extensions cannot be deleted either');

SELECT ok(to_regclass('public.fc10_accounts') IS NOT NULL AND to_regclass('public.fc10_acctinfo') IS NOT NULL,
    'the refused delete of that base dropped nothing');

-- A family across two modules.
INSERT INTO modules (module_name) VALUES ('fc10_mod_a'), ('fc10_mod_b');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fc10x_parties', 'Party', 'Parties', (SELECT id FROM modules WHERE module_name = 'fc10_mod_a'), 'typeid', 'fcjxpty');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('fc10x_orgs', 'Organization', 'Organizations', (SELECT id FROM modules WHERE module_name = 'fc10_mod_b'),
        'is_a', 'fcjxorg', 'fc10x_parties');

SELECT throws_ok($$DELETE FROM modules WHERE module_name = 'fc10_mod_a'$$,
    '90248', NULL,
    'a module whose root has a child in another module cannot be deleted');

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'fc10_mod_b'$$,
    'the module with the child can be deleted');

SELECT lives_ok($$DELETE FROM modules WHERE module_name = 'fc10_mod_a'$$,
    'then the module with the root can be deleted');

SELECT ok(
    to_regclass('public.fc10x_parties') IS NULL AND to_regclass('public.fc10x_orgs') IS NULL
    AND to_regclass('public.fc10x_orgs_ext') IS NULL
    AND NOT EXISTS (SELECT 1 FROM entities WHERE table_name IN ('fc10x_parties', 'fc10x_orgs')),
    'the two module deletes took both entities and every relation');

-- Taking a family apart, level by level.
SELECT pg_temp.fc_build('fc10b_', 'fcjb');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity,
                      view_permission, edit_permission)
VALUES ('fc10b_clients', 'Client', 'Clients', 1, 'has_a', 'fc10b_parties', 'nwind:view', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc10b_clients', 'credit', 'Credit', 'int32', 30);

DELETE FROM fc10b_vendors;
DELETE FROM fc10b_banks;
DELETE FROM fc10b_orgs;
DELETE FROM fc10b_persons;
DELETE FROM fc10b_parties;

SELECT is((SELECT count(*)::INTEGER FROM fc10b_parties), 0,
    'every level is emptied through its own entity');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10b_orgs'$$,
    '90248', NULL,
    'a middle level with a child cannot be deleted even when every level is empty');

SELECT ok(pg_temp.fc_intact('fc10b_'),
    'the refused delete of the empty middle level dropped nothing');

SELECT throws_ok($$DELETE FROM entities WHERE table_name = 'fc10b_parties'$$,
    '90248', NULL,
    'an empty root with dependents cannot be deleted');

SELECT ok(pg_temp.fc_intact('fc10b_'),
    'the refused delete of the empty root dropped nothing');

INSERT INTO fc10b_parties (label) VALUES ('P2');
INSERT INTO fc10b_vendors (id, terms) SELECT id, 'net30' FROM fc10b_parties WHERE label = 'P2';

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_clients'$$,
    'an empty extension that is not the last one is deleted');

SELECT ok(
    to_regclass('public.fc10b_clients') IS NULL AND to_regclass('public.fc10b_clients_ext') IS NULL
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('record_write_fc10b_clients', 'view_write_fc10b_clients')),
    'the deleted extension''s view, part and routines are gone');

SELECT is(pg_temp.fc_args('fc10b_parties', 'a_has_a_guard'), 'id,fc10b_vendors,',
    'the base''s delete guard is rebuilt with the remaining extension');

SELECT throws_ok($$DELETE FROM fc10b_parties WHERE label = 'P2'$$,
    '90251', NULL,
    'the rebuilt guard still protects a base record with an extension');

DELETE FROM fc10b_vendors;

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_vendors'$$,
    'the last extension, once empty, is deleted');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fc10b_parties') AND tgname = 'a_has_a_guard'),
    'with no extension left, the base loses its delete guard');

SELECT lives_ok($$DELETE FROM fc10b_parties WHERE label = 'P2'$$,
    'a base record can be deleted again');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_banks'$$,
    'an empty grandchild is deleted');

SELECT ok(
    to_regclass('public.fc10b_banks') IS NULL AND to_regclass('public.fc10b_banks_ext') IS NULL
    AND pg_temp.fc_args('fc10b_parties', 'typeid_assign') NOT LIKE '%fcjbbnk%',
    'the deleted grandchild''s relations are gone and the root no longer accepts its prefix');

SELECT lives_ok($$INSERT INTO fc10b_orgs (label, city, vat) VALUES ('O2', 'Oulu', 'FI2')$$,
    'the middle level, rebuilt without its child, is written through its view');

SELECT is(pg_temp.fc_write($$UPDATE fc10b_parties SET city = 'Oslo' WHERE label = 'O2'$$,
                           $$SELECT city FROM fc10b_orgs WHERE label = 'O2'$$),
    'Oslo',
    'the middle level, rebuilt without its child, is written through the root');

DELETE FROM fc10b_orgs WHERE label = 'O2';

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_orgs'$$,
    'the middle level, with no child and no records, is deleted');

SELECT is(pg_temp.fc_args('fc10b_parties', 'typeid_assign'), 'id,fcjbpty,fcjbper,',
    'the root''s typeid_assign keeps the prefix of the remaining subtype only');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_persons'$$,
    'the last subtype is deleted');

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass('public.fc10b_parties') AND tgname = 'a_is_a_dispatch')
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_a_dispatch_fc10b_parties'),
    'with no subtype left, the root loses its dispatch trigger and routine');

INSERT INTO fc10b_parties (label, city) VALUES ('P3', 'Pula');

SELECT is(pg_temp.fc_write($$UPDATE fc10b_parties SET city = 'Pola' WHERE label = 'P3'$$,
                           $$SELECT city || '/' || common.typeid_prefix(id) FROM fc10b_parties WHERE label = 'P3'$$),
    'Pola/fcjbpty',
    'the former root is written like any typeid entity');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc10b_parties'$$,
    'the former root is deleted like a plain entity, with its records');

SELECT is(
    (SELECT count(*)::INTEGER FROM (
        SELECT relname::TEXT FROM pg_class WHERE relname LIKE '%fc10b\_%'
        UNION ALL SELECT proname::TEXT FROM pg_proc WHERE proname LIKE '%fc10b\_%' OR prosrc LIKE '%fc10b\_%'
        UNION ALL SELECT tgname::TEXT FROM pg_trigger WHERE tgname LIKE '%fc10b\_%'
        UNION ALL SELECT polname::TEXT FROM pg_policy WHERE polname LIKE '%fc10b\_%') s),
    0,
    'no relation, routine, trigger or policy of the family is left');

-- =====================================================
-- PART 11: objects built on family views
-- =====================================================
-- The family refresh replaces every view of a family, and PostgreSQL drops
-- what depends on a view with it. An object of another author built on a
-- family view - a report view, say - would vanish without a word on a field
-- add, so a change that rebuilds the family is refused while one exists, and
-- the refusal names it. The dictionary's own objects do not count, and a view
-- over the root table is not touched by a rebuild at all.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');
SELECT pg_temp.fc_build('fc11_', 'fck');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('fc11_parties', 'fc11spare', 'Spare', 'text', 50);

RESET ROLE;
CREATE VIEW public.fc11_bank_report AS SELECT id, label, bic FROM public.fc11_banks;
SELECT authenticate_as('user3');

INSERT INTO fc_marks VALUES ('fc11 before', pg_temp.fc_snapshot('fc11_parties'));

SELECT is(pg_temp.sqlstate_of($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                                VALUES ('fc11_parties', 'fc11extra', 'Extra', 'text', 60)$$),
    '90256',
    'a root field add is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                            VALUES ('fc11_parties', 'fc11extra', 'Extra', 'text', 60)$$) LIKE '%fc11_bank_report%',
    'the refused root field add names that view');

SELECT is(pg_temp.sqlstate_of($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fc11_orgs' AND field_name = 'vat'$$),
    '90256',
    'a middle-level field change is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fc11_orgs' AND field_name = 'vat'$$)
          LIKE '%fc11_bank_report%',
    'the refused middle-level field change names that view');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET table_name = 'fc11_people' WHERE table_name = 'fc11_parties'$$),
    '90256',
    'a root rename is refused while a view of another author is built on a family view');

SELECT ok(pg_temp.hint_of($$UPDATE entities SET table_name = 'fc11_people' WHERE table_name = 'fc11_parties'$$)
          LIKE '%fc11_bank_report%',
    'the refused root rename names that view');

-- A field delete and a searchable change drop, with CASCADE, columns the views
-- show before the family is rebuilt; a prefix change and a change of a level's
-- rules rebuild the family too. Each is refused the same way.
SELECT is(pg_temp.sqlstate_of($$DELETE FROM fields WHERE table_name = 'fc11_parties' AND field_name = 'fc11spare'$$),
    '90256',
    'a root field delete is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of($$UPDATE fields SET searchable = FALSE WHERE table_name = 'fc11_parties' AND field_name = 'label'$$),
    '90256',
    'a searchable change on the root is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of($$UPDATE entities SET id_prefix = 'fckptytwo' WHERE table_name = 'fc11_parties'$$),
    '90256',
    'a root prefix change is refused while a view of another author is built on a family view');

SELECT is(pg_temp.sqlstate_of(
    $$UPDATE entities
         SET validation_rules = '[{"code": "99111", "message": "always passes", "jsonlogic": true}]'::jsonb
       WHERE table_name = 'fc11_orgs'$$),
    '90256',
    'rules added to a middle level are refused while a view of another author is built on a family view');

-- Once more outside pg_temp.sqlstate_of, which rolls a statement back whatever
-- it did, so the comparison below sees what a refused change leaves behind.
SELECT throws_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                   VALUES ('fc11_parties', 'fc11extra', 'Extra', 'text', 60)$$,
    '90256', NULL,
    'a root field add is refused while a view of another author is built on a family view');

SELECT is(pg_temp.fc_snapshot('fc11_parties'), (SELECT v FROM fc_marks WHERE k = 'fc11 before'),
    'the refused change leaves every view, routine and trigger of the family as it was');

SELECT ok(to_regclass('public.fc11_bank_report') IS NOT NULL,
    'the refused change leaves the view built on the family in place');

RESET ROLE;
DROP VIEW IF EXISTS public.fc11_bank_report;
SELECT authenticate_as('user3');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fc11_parties', 'fc11more', 'More', 'text', 70)$$,
    'once the view is dropped, the root field add goes through');

SELECT lives_ok($$UPDATE fields SET title = 'VAT Number' WHERE table_name = 'fc11_orgs' AND field_name = 'vat'$$,
    'once the view is dropped, the middle-level field change goes through');

-- The dictionary's own objects on a family view.
INSERT INTO entities (table_name, singular_label, plural_label, module_id) VALUES ('fc11_notes', 'Note', 'Notes', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('fc11_notes', 'bank_id', 'Bank', 'reference', 'fc11_banks', 'restrict', 30);
UPDATE entities SET select_rule = '{"!=": [{"var": "bic"}, "never"]}'::jsonb WHERE table_name = 'fc11_banks';

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fc11_parties', 'fc11last', 'Last', 'text', 80)$$,
    'the family''s own views and routines, a referencing entity''s label function and a select_rule block no change');

DELETE FROM entities WHERE table_name = 'fc11_notes';
UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'fc11_banks';

-- A view over the root table.
RESET ROLE;
CREATE VIEW public.fc11_party_report AS SELECT id, label FROM public.fc11_parties;
SELECT authenticate_as('user3');

SELECT lives_ok($$INSERT INTO fields (table_name, field_name, title, format, field_order)
                  VALUES ('fc11_parties', 'fc11again', 'Again', 'text', 90)$$,
    'a view over the root table does not block a root field add, as for a plain entity');

SELECT ok(to_regclass('public.fc11_party_report') IS NOT NULL,
    'the view over the root table survives the root field add');

-- Deleting a subtype rebuilds its base's family.
DELETE FROM fc11_vendors;
DELETE FROM fc11_banks;

RESET ROLE;
CREATE VIEW public.fc11_org_report AS SELECT id, vat FROM public.fc11_orgs;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM entities WHERE table_name = 'fc11_banks'$$), '90256',
    'deleting a subtype is refused while a view of another author is built on its base''s view');

SELECT ok(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'fc11_banks'$$) LIKE '%fc11_org_report%',
    'the refused subtype delete names the view on its base''s view');

RESET ROLE;
DROP VIEW public.fc11_org_report;
CREATE VIEW public.fc11_bank_report AS SELECT id, bic FROM public.fc11_banks;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM entities WHERE table_name = 'fc11_banks'$$), '90256',
    'deleting a subtype is refused while a view of another author is built on its own view');

SELECT ok(pg_temp.hint_of($$DELETE FROM entities WHERE table_name = 'fc11_banks'$$) LIKE '%fc11_bank_report%',
    'the refused subtype delete names the view on its own view');

SELECT ok(to_regclass('public.fc11_banks') IS NOT NULL,
    'the refused subtype is still there');

RESET ROLE;
DROP VIEW public.fc11_bank_report;
SELECT authenticate_as('user3');

SELECT lives_ok($$DELETE FROM entities WHERE table_name = 'fc11_banks'$$,
    'once the view is dropped, the subtype is deleted');

SELECT lives_ok($$UPDATE entities SET table_name = 'fc11_people' WHERE table_name = 'fc11_parties'$$,
    'with no view of another author on its views, the root is renamed');

-- A module delete takes the family's views as well.
INSERT INTO modules (module_name) VALUES ('fc11_mod');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('fc11m_parties', 'Party', 'Parties', (SELECT id FROM modules WHERE module_name = 'fc11_mod'), 'typeid', 'fckmpty');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('fc11m_orgs', 'Organization', 'Organizations', (SELECT id FROM modules WHERE module_name = 'fc11_mod'),
        'is_a', 'fckmorg', 'fc11m_parties');

RESET ROLE;
CREATE VIEW public.fc11m_org_report AS SELECT id FROM public.fc11m_orgs;
SELECT authenticate_as('user3');

SELECT is(pg_temp.sqlstate_of($$DELETE FROM modules WHERE module_name = 'fc11_mod'$$), '90256',
    'a module delete is refused while a view of another author is built on one of its family views');

SELECT * FROM finish();
ROLLBACK;
