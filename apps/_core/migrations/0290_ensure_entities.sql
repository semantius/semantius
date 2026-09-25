-- =====================================================
-- ENTITY DEFINITIONS: jsonc_to_jsonb, ensure_entities
-- =====================================================
-- A migration file named NNNN_name.jsonc holds entity metadata as a
-- declarative document in the semantius-cli export format (version 1) with
-- JSONC comments allowed. Every migration runner executes it as
--
--   SELECT public.ensure_entities(public.jsonc_to_jsonb(<the file text, dollar-quoted>));
--
-- (the dollar tag is JSONC_TAG in packages/core/src/migrate.ts), so the parsing and the diffing live here, once, and no runner needs a JSONC
-- parser. A .jsonc file is repeatable: it runs again whenever its text
-- changes, and ensure_entities then writes only what differs from the database.
--
-- The rules are those of the semantius-cli import:
--   * metadata is matched by name (module_name, permission_name, role slug,
--     table_name, (table_name, field_name)), never by id, and never written
--     with ON CONFLICT - an upsert would put the create-only columns into its
--     SET list and fire their triggers;
--   * create-only columns (catalog codes, id_column, a role's origin and slug,
--     a module's module_type, a field's ctype) are written on insert only;
--   * an omitted key takes the column default on insert and is left untouched
--     on update; an explicit null writes NULL;
--   * nothing is ever deleted.
-- Order of work: module, permissions, permission hierarchy, roles, grants, the
-- module's permission and default-role columns; entities without the columns
-- that name fields; fields, in array order (array order is creation order, so
-- it fixes the physical column order); then the entity columns that name
-- fields (label_parent, computed_fields, validation_rules, select_rule); then
-- the records, so every record is written under the entity's rules on a first
-- apply as on a re-apply.
--
-- All four functions are SECURITY INVOKER and granted to nobody: they run as
-- the installing role, inside a migration. Their errors are install-time errors
-- and use PostgreSQL's own SQLSTATEs (22023 for a malformed definition, 0A000
-- for a change that is not additive), like the other exemptions listed in
-- docs/error-contract.md.
-- =====================================================
-- jsonc_to_jsonb
-- =====================================================
-- JSONC = JSON plus // and /* */ comments, trailing commas and a byte order
-- mark (CRLF needs nothing: \r is JSON whitespace). The text is cut into
-- tokens - a string literal, a comment, a run of other characters, or a single
-- character - so a comment marker or a comma inside a string is never touched.
-- Comments become one space (so they still separate tokens), and a comma
-- followed only by whitespace and a closing bracket is dropped from the text
-- between two strings. Whatever is left must be JSON; the cast reports what is
-- not. An unterminated string matches no string token, stays as a lone quote
-- and fails the cast.
--
-- The alternation relies on PostgreSQL's leftmost-longest regex semantics:
-- "//x" matches the comment branch rather than the single-character one
-- because it is longer. The block-comment branch is written without a
-- non-greedy quantifier on purpose - in PostgreSQL the first quantifier of a
-- regex decides the greediness of the whole match.
CREATE OR REPLACE FUNCTION public.jsonc_to_jsonb(jsonc TEXT)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE STRICT
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $fn$
    WITH tokens AS (
        SELECT t.i, t.m[1] AS tok
          FROM regexp_matches(
                   regexp_replace(jsonc, '^' || chr(65279), ''),
                   '("(?:[^"\\]|\\.)*"|//[^\n]*|/\*(?:[^*]|\*+[^*/])*\*+/|[^"/]+|.)',
                   'g') WITH ORDINALITY AS t(m, i)
    ), kinds AS (
        SELECT i, tok,
               length(tok) >= 2 AND left(tok, 1) = '"' AND right(tok, 1) = '"' AS is_string,
               left(tok, 2) IN ('//', '/*') AS is_comment
          FROM tokens
    ), runs AS (
        -- Every non-string token gets the number of strings before it, so the
        -- tokens between two strings share one run.
        SELECT i, tok, is_string, is_comment,
               count(*) FILTER (WHERE is_string) OVER (ORDER BY i) AS run
          FROM kinds
    ), pieces AS (
        SELECT min(i) AS ord,
               regexp_replace(
                   string_agg(CASE WHEN is_comment THEN ' ' ELSE tok END, '' ORDER BY i),
                   ',(\s*[\]}])', '\1', 'g') AS piece
          FROM runs
         WHERE NOT is_string
         GROUP BY run
        UNION ALL
        SELECT i, tok FROM runs WHERE is_string
    )
    SELECT coalesce(string_agg(piece, '' ORDER BY ord), '')::jsonb FROM pieces
$fn$;

COMMENT ON FUNCTION public.jsonc_to_jsonb(TEXT) IS
'Parses JSONC (JSON with // and /* */ comments, trailing commas and a byte order mark) into jsonb. Comment markers and commas inside strings are left alone. Used by the migration runners to apply .jsonc entity definitions through ensure_entities().';

REVOKE EXECUTE ON FUNCTION public.jsonc_to_jsonb(TEXT) FROM PUBLIC;

-- =====================================================
-- ensure_entities_insert_rows: new rows in one statement
-- =====================================================
-- Inserts the objects of p_rows, in array order, with one INSERT. A key an
-- object omits is written as DEFAULT for that row, so "omitted means the
-- column default" holds even when the rows of one statement set different
-- columns. One statement rather than one per row matters for the fields
-- table: the dictionary coalesces its statement-level work (the search_vector
-- rebuild) per statement, which decides where that column lands.
CREATE OR REPLACE FUNCTION public.ensure_entities_insert_rows(p_table TEXT, p_rows JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    v_rel    TEXT := format('public.%I', p_table);
    v_cols   TEXT[];
    v_values TEXT;
BEGIN
    SELECT array_agg(k ORDER BY k) INTO v_cols
      FROM (SELECT DISTINCT jsonb_object_keys(r) AS k FROM jsonb_array_elements(p_rows) r) s;
    IF v_cols IS NULL THEN
        RETURN;
    END IF;
    SELECT string_agg(
             '(' || (SELECT string_agg(
                               CASE WHEN r ? c
                                    THEN format('(jsonb_populate_record(NULL::%s, $1 -> %s)).%I', v_rel, i - 1, c)
                                    ELSE 'DEFAULT' END,
                               ', ' ORDER BY c)
                       FROM unnest(v_cols) AS c) || ')',
             ', ' ORDER BY i)
      INTO v_values
      FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS t(r, i);
    EXECUTE format('INSERT INTO %s (%s) VALUES %s', v_rel,
                   (SELECT string_agg(format('%I', c), ', ' ORDER BY c) FROM unnest(v_cols) AS c),
                   v_values)
    USING p_rows;
END;
$fn$;

COMMENT ON FUNCTION public.ensure_entities_insert_rows(TEXT, JSONB) IS
'Internal to ensure_entities(): inserts a JSON array of rows into a metadata table with one INSERT, in array order, a key a row omits taking the column default.';

REVOKE EXECUTE ON FUNCTION public.ensure_entities_insert_rows(TEXT, JSONB) FROM PUBLIC;

-- =====================================================
-- ensure_entities_row: one metadata row
-- =====================================================
-- Makes one row of a metadata table look as p_row describes: inserts it when
-- no row matches p_key, otherwise updates only the columns whose value
-- differs, and writes nothing when none does. Values are compared after the
-- same coercion the write applies (jsonb_populate_record on the table's row
-- type), so "10" and 10 for an integer column are the same value. Columns in
-- p_create_only and the key columns are never updated. Returns 'created',
-- 'updated' or 'unchanged'.
CREATE OR REPLACE FUNCTION public.ensure_entities_row(
    p_table       TEXT,
    p_key         JSONB,
    p_row         JSONB,
    p_create_only TEXT[],
    p_label       TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    v_rel     TEXT := format('public.%I', p_table);
    v_where   TEXT;
    v_current JSONB;
    v_wanted  JSONB;
    v_cols    TEXT[];
    v_changed TEXT[];
BEGIN
    SELECT string_agg(format('t.%1$I = k.%1$I', key), ' AND ')
      INTO v_where
      FROM jsonb_object_keys(p_key) AS key;

    EXECUTE format(
        'SELECT to_jsonb(t) FROM %1$s t, jsonb_populate_record(NULL::%1$s, $1) k WHERE %2$s',
        v_rel, v_where)
       INTO v_current USING p_key;

    SELECT array_agg(key ORDER BY key) INTO v_cols FROM jsonb_object_keys(p_row) AS key;

    IF v_current IS NULL THEN
        PERFORM ensure_entities_insert_rows(p_table, jsonb_build_array(p_row));
        -- The dictionary's field trigger lowers client_min_messages to WARNING
        -- for the rest of the transaction (SET LOCAL); restore the level the
        -- caller had when ensure_entities started, or this NOTICE is lost.
        PERFORM set_config('client_min_messages',
                           coalesce(current_setting('semantius.notice_level', true),
                                    current_setting('client_min_messages')), true);
        RAISE NOTICE 'ensure_entities: created %', p_label;
        RETURN 'created';
    END IF;

    EXECUTE format('SELECT to_jsonb(jsonb_populate_record(NULL::%s, $1))', v_rel)
       INTO v_wanted USING p_row;

    SELECT array_agg(c ORDER BY c)
      INTO v_changed
      FROM unnest(v_cols) AS c
     WHERE NOT (p_key ? c)
       AND c <> ALL (coalesce(p_create_only, ARRAY[]::TEXT[]))
       AND (v_wanted -> c) IS DISTINCT FROM (v_current -> c);

    IF v_changed IS NULL THEN
        RETURN 'unchanged';
    END IF;

    EXECUTE format(
        'UPDATE %1$s t SET %2$s FROM jsonb_populate_record(NULL::%1$s, $1) r, jsonb_populate_record(NULL::%1$s, $2) k WHERE %3$s',
        v_rel,
        (SELECT string_agg(format('%1$I = r.%1$I', c), ', ' ORDER BY c) FROM unnest(v_changed) AS c),
        v_where)
    USING p_row, p_key;
    PERFORM set_config('client_min_messages',
                       coalesce(current_setting('semantius.notice_level', true),
                                current_setting('client_min_messages')), true);
    RAISE NOTICE 'ensure_entities: updated % (%)', p_label, array_to_string(v_changed, ', ');
    RETURN 'updated';
END;
$fn$;

COMMENT ON FUNCTION public.ensure_entities_row(TEXT, JSONB, JSONB, TEXT[], TEXT) IS
'Internal to ensure_entities(): inserts one metadata row, or updates only the columns that differ, never the key or create-only columns. Returns created, updated or unchanged.';

REVOKE EXECUTE ON FUNCTION public.ensure_entities_row(TEXT, JSONB, JSONB, TEXT[], TEXT) FROM PUBLIC;

-- =====================================================
-- ensure_entities
-- =====================================================
CREATE OR REPLACE FUNCTION public.ensure_entities(definition JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
    -- Keys the export carries but nothing writes: computed by the platform or
    -- implied by the document's structure.
    c_entity_ignored CONSTANT TEXT[] := ARRAY['searchable', 'is_child', 'plural', 'id',
        'created_at', 'updated_at', 'module_id', 'search_vector'];
    c_entity_create_only CONSTANT TEXT[] := ARRAY['id_column', 'catalog_entity_code',
        'catalog_entity_aliases'];
    -- Written once the fields exist, because they name fields.
    c_entity_deferred CONSTANT TEXT[] := ARRAY['label_parent', 'computed_fields',
        'validation_rules', 'select_rule'];
    c_field_ignored CONSTANT TEXT[] := ARRAY['id', 'table_name', 'created_at', 'updated_at',
        'search_vector'];
    c_field_create_only CONSTANT TEXT[] := ARRAY['ctype', 'catalog_field_code'];
    c_module_ignored CONSTANT TEXT[] := ARRAY['id', 'created_at', 'updated_at', 'version',
        'version_date', 'search_vector', 'default_viewer_role_id', 'default_manager_role_id',
        'default_admin_role_id'];
    c_module_create_only CONSTANT TEXT[] := ARRAY['module_type', 'catalog_module_code'];
    c_module_role_keys CONSTANT TEXT[] := ARRAY['default_viewer_role_slug',
        'default_manager_role_slug', 'default_admin_role_slug'];
    c_module_deferred CONSTANT TEXT[] := ARRAY['view_permission', 'manage_permission',
        'admin_permission', 'default_viewer_role_slug', 'default_manager_role_slug',
        'default_admin_role_slug'];
    c_permission_ignored CONSTANT TEXT[] := ARRAY['module_id', 'created_at', 'updated_at',
        'search_vector'];
    c_role_ignored CONSTANT TEXT[] := ARRAY['id', 'module_id', 'created_at', 'updated_at',
        'search_vector'];
    c_role_create_only CONSTANT TEXT[] := ARRAY['origin', 'slug'];

    v_entity_keys     TEXT[];
    v_field_keys      TEXT[];
    v_module_keys     TEXT[];
    v_permission_keys TEXT[];
    v_role_keys       TEXT[];

    v_summary   JSONB := jsonb_build_object(
        'entities', jsonb_build_object('created', '[]'::jsonb, 'updated', '[]'::jsonb),
        'fields', jsonb_build_object('created', '[]'::jsonb, 'updated', '[]'::jsonb),
        'fields_not_in_definition', '[]'::jsonb,
        'records', '{}'::jsonb);
    v_module    JSONB;
    v_module_id INTEGER;
    v_entries   JSONB;
    v_entry     JSONB;
    v_entity    JSONB;
    v_field     JSONB;
    v_item      JSONB;
    v_row       JSONB;
    v_key       TEXT;
    v_bad       TEXT;
    v_status    TEXT;
    v_table     TEXT;
    v_current   public.entities%ROWTYPE;
    v_idx       INTEGER;
    v_batch     JSONB;
    v_batch_n   INTEGER;
    v_role_id   INTEGER;
    v_label     TEXT;
    v_n         BIGINT;
    v_m         BIGINT;
BEGIN
    -- The NOTICE level to restore before each NOTICE; see ensure_entities_row.
    PERFORM set_config('semantius.notice_level', current_setting('client_min_messages'), true);

    -- ---------------------------------------------------------------
    -- 1. Validate the whole document before writing anything.
    -- ---------------------------------------------------------------
    SELECT array_agg(attname::TEXT) INTO v_entity_keys FROM pg_attribute
     WHERE attrelid = 'public.entities'::regclass AND attnum > 0 AND NOT attisdropped
       AND attname::TEXT <> ALL (c_entity_ignored);
    v_entity_keys := v_entity_keys || ARRAY['module_name', 'fields'];
    SELECT array_agg(attname::TEXT) INTO v_field_keys FROM pg_attribute
     WHERE attrelid = 'public.fields'::regclass AND attnum > 0 AND NOT attisdropped
       AND attname::TEXT <> ALL (c_field_ignored);
    SELECT array_agg(attname::TEXT) INTO v_module_keys FROM pg_attribute
     WHERE attrelid = 'public.modules'::regclass AND attnum > 0 AND NOT attisdropped
       AND attname::TEXT <> ALL (c_module_ignored);
    v_module_keys := v_module_keys || c_module_role_keys;
    SELECT array_agg(attname::TEXT) INTO v_permission_keys FROM pg_attribute
     WHERE attrelid = 'public.permissions'::regclass AND attnum > 0 AND NOT attisdropped
       AND attname::TEXT <> ALL (c_permission_ignored);
    SELECT array_agg(attname::TEXT) INTO v_role_keys FROM pg_attribute
     WHERE attrelid = 'public.roles'::regclass AND attnum > 0 AND NOT attisdropped
       AND attname::TEXT <> ALL (c_role_ignored);

    IF definition IS NULL OR jsonb_typeof(definition) <> 'object' THEN
        RAISE EXCEPTION 'ensure_entities: the definition must be a JSON object'
            USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(definition) AS k
     WHERE k <> ALL (ARRAY['version', 'module', 'permissions', 'permission_hierarchy',
                           'roles', 'role_permissions', 'entities']);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'ensure_entities: unknown top-level key(s): %', v_bad
            USING ERRCODE = '22023';
    END IF;
    IF definition -> 'version' IS DISTINCT FROM '1'::jsonb THEN
        RAISE EXCEPTION 'ensure_entities: "version" must be 1, not %',
            coalesce((definition -> 'version')::TEXT, 'missing')
            USING ERRCODE = '22023';
    END IF;
    FOREACH v_key IN ARRAY ARRAY['permissions', 'permission_hierarchy', 'roles',
                                 'role_permissions', 'entities'] LOOP
        IF definition ? v_key AND jsonb_typeof(definition -> v_key) <> 'array' THEN
            RAISE EXCEPTION 'ensure_entities: "%" must be an array', v_key
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    v_module := definition -> 'module';
    IF v_module IS NOT NULL THEN
        IF jsonb_typeof(v_module) <> 'object'
           OR jsonb_typeof(v_module -> 'module_name') IS DISTINCT FROM 'string'
           OR v_module ->> 'module_name' = '' THEN
            RAISE EXCEPTION 'ensure_entities: "module" must be an object with a module_name'
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_module) AS k
         WHERE k <> ALL (v_module_keys);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: module %: unknown key(s): %',
                v_module ->> 'module_name', v_bad USING ERRCODE = '22023';
        END IF;
        IF v_module ? 'module_slug' AND v_module ->> 'module_slug' = '' THEN
            RAISE EXCEPTION 'ensure_entities: module %: an empty module_slug is derived by a trigger; omit it instead',
                v_module ->> 'module_name' USING ERRCODE = '22023';
        END IF;
    ELSIF jsonb_array_length(coalesce(definition -> 'permissions', '[]')) > 0
       OR jsonb_array_length(coalesce(definition -> 'roles', '[]')) > 0 THEN
        RAISE EXCEPTION 'ensure_entities: permissions and roles belong to the document''s "module", which is missing'
            USING ERRCODE = '22023';
    END IF;

    FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'permissions', '[]')) e LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item -> 'permission_name') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'ensure_entities: every permission needs a permission_name'
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_item) AS k
         WHERE k <> ALL (v_permission_keys);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: permission %: unknown key(s): %',
                v_item ->> 'permission_name', v_bad USING ERRCODE = '22023';
        END IF;
    END LOOP;

    FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'permission_hierarchy', '[]')) e LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item -> 'including_permission_name') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_item -> 'included_permission_name') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'ensure_entities: every permission_hierarchy row needs including_permission_name and included_permission_name'
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_item) AS k
         WHERE k <> ALL (ARRAY['including_permission_name', 'included_permission_name', 'origin']);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: permission_hierarchy: unknown key(s): %', v_bad
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'roles', '[]')) e LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item -> 'slug') IS DISTINCT FROM 'string'
           OR v_item ->> 'slug' = '' THEN
            RAISE EXCEPTION 'ensure_entities: every role needs a slug (roles are matched by slug)'
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_item) AS k
         WHERE k <> ALL (v_role_keys);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: role %: unknown key(s): %',
                v_item ->> 'slug', v_bad USING ERRCODE = '22023';
        END IF;
    END LOOP;

    FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'role_permissions', '[]')) e LOOP
        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item -> 'role_slug') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_item -> 'permission_name') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'ensure_entities: every role_permissions row needs role_slug and permission_name'
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_item) AS k
         WHERE k <> ALL (ARRAY['role_slug', 'permission_name']);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: role_permissions: unknown key(s): %', v_bad
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    v_entries := coalesce(definition -> 'entities', '[]');
    FOR v_entry IN SELECT e FROM jsonb_array_elements(v_entries) e LOOP
        v_entity := v_entry -> 'entity';
        IF jsonb_typeof(v_entry) <> 'object'
           OR jsonb_typeof(v_entity) IS DISTINCT FROM 'object'
           OR jsonb_typeof(v_entity -> 'table_name') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'ensure_entities: every entry of "entities" needs an "entity" with a table_name'
                USING ERRCODE = '22023';
        END IF;
        v_table := v_entity ->> 'table_name';
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_entry) AS k
         WHERE k <> ALL (ARRAY['entity', 'records']);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: entry %: unknown key(s): %', v_table, v_bad
                USING ERRCODE = '22023';
        END IF;
        IF v_entry ? 'records' AND jsonb_typeof(v_entry -> 'records') <> 'array' THEN
            RAISE EXCEPTION 'ensure_entities: the records of % must be an array', v_table
                USING ERRCODE = '22023';
        END IF;
        SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_entity) AS k
         WHERE k <> ALL (v_entity_keys) AND k <> ALL (c_entity_ignored);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'ensure_entities: entity %: unknown key(s): %', v_table, v_bad
                USING ERRCODE = '22023';
        END IF;
        -- Values a trigger would rewrite: stored differently from the file,
        -- they would make every later apply see a change that is not one.
        FOREACH v_key IN ARRAY ARRAY['singular', 'singular_label'] LOOP
            IF v_entity ? v_key AND coalesce(v_entity ->> v_key, '') = '' THEN
                RAISE EXCEPTION 'ensure_entities: entity %: an empty % is derived by a trigger; omit it instead',
                    v_table, v_key USING ERRCODE = '22023';
            END IF;
        END LOOP;
        IF v_entity ? 'fields' AND jsonb_typeof(v_entity -> 'fields') <> 'array' THEN
            RAISE EXCEPTION 'ensure_entities: the fields of % must be an array', v_table
                USING ERRCODE = '22023';
        END IF;
        FOR v_field IN SELECT f FROM jsonb_array_elements(coalesce(v_entity -> 'fields', '[]')) f LOOP
            IF jsonb_typeof(v_field) <> 'object'
               OR jsonb_typeof(v_field -> 'field_name') IS DISTINCT FROM 'string' THEN
                RAISE EXCEPTION 'ensure_entities: every field of % needs a field_name', v_table
                    USING ERRCODE = '22023';
            END IF;
            SELECT string_agg(k, ', ') INTO v_bad FROM jsonb_object_keys(v_field) AS k
             WHERE k <> ALL (v_field_keys) AND k <> ALL (c_field_ignored);
            IF v_bad IS NOT NULL THEN
                RAISE EXCEPTION 'ensure_entities: field %.%: unknown key(s): %',
                    v_table, v_field ->> 'field_name', v_bad USING ERRCODE = '22023';
            END IF;
            IF v_field -> 'field_order' = '0'::jsonb THEN
                RAISE EXCEPTION 'ensure_entities: field %.%: field_order 0 is replaced by a trigger; give a position or omit it',
                    v_table, v_field ->> 'field_name' USING ERRCODE = '22023';
            END IF;
            IF v_field ? 'enum_values' AND jsonb_typeof(v_field -> 'enum_values') NOT IN ('array', 'null') THEN
                RAISE EXCEPTION 'ensure_entities: field %.%: enum_values must be an array or null',
                    v_table, v_field ->> 'field_name' USING ERRCODE = '22023';
            END IF;
        END LOOP;
        FOR v_item IN SELECT r FROM jsonb_array_elements(coalesce(v_entry -> 'records', '[]')) r LOOP
            IF jsonb_typeof(v_item) <> 'object' THEN
                RAISE EXCEPTION 'ensure_entities: every record of % must be an object', v_table
                    USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 2. The module sections, matched by name.
    -- ---------------------------------------------------------------
    IF v_module IS NOT NULL THEN
        v_label := 'module ' || (v_module ->> 'module_name');
        SELECT jsonb_object_agg(key, value) INTO v_row
          FROM jsonb_each(v_module) WHERE key <> ALL (c_module_deferred);
        v_status := ensure_entities_row('modules',
            jsonb_build_object('module_name', v_module -> 'module_name'),
            v_row, c_module_create_only, v_label);
        v_summary := v_summary || jsonb_build_object('module', v_status);
        SELECT id INTO v_module_id FROM modules WHERE module_name = v_module ->> 'module_name';

        v_summary := v_summary || jsonb_build_object('permissions',
            jsonb_build_object('created', '[]'::jsonb, 'updated', '[]'::jsonb));
        FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'permissions', '[]')) e LOOP
            v_status := ensure_entities_row('permissions',
                jsonb_build_object('permission_name', v_item -> 'permission_name'),
                v_item || jsonb_build_object('module_id', v_module_id),
                ARRAY['module_id'], 'permission ' || (v_item ->> 'permission_name'));
            IF v_status <> 'unchanged' THEN
                v_summary := jsonb_insert(v_summary, ARRAY['permissions', v_status, '-1'],
                                          v_item -> 'permission_name', true);
            END IF;
        END LOOP;

        v_summary := v_summary || jsonb_build_object('permission_hierarchy',
            jsonb_build_object('created', '[]'::jsonb));
        FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'permission_hierarchy', '[]')) e LOOP
            -- Never updated: origin is immutable once set.
            IF NOT EXISTS (SELECT 1 FROM permission_hierarchy h
                            WHERE h.including_permission_name = v_item ->> 'including_permission_name'
                              AND h.included_permission_name = v_item ->> 'included_permission_name') THEN
                PERFORM ensure_entities_row('permission_hierarchy',
                    v_item - 'origin', v_item, NULL,
                    format('permission hierarchy %s -> %s',
                           v_item ->> 'including_permission_name', v_item ->> 'included_permission_name'));
                v_summary := jsonb_insert(v_summary, ARRAY['permission_hierarchy', 'created', '-1'],
                    to_jsonb((v_item ->> 'including_permission_name') || ' -> ' || (v_item ->> 'included_permission_name')), true);
            END IF;
        END LOOP;

        v_summary := v_summary || jsonb_build_object('roles',
            jsonb_build_object('created', '[]'::jsonb, 'updated', '[]'::jsonb));
        FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'roles', '[]')) e LOOP
            v_status := ensure_entities_row('roles',
                jsonb_build_object('slug', v_item -> 'slug'),
                v_item || jsonb_build_object('module_id', v_module_id),
                c_role_create_only || ARRAY['module_id'], 'role ' || (v_item ->> 'slug'));
            IF v_status <> 'unchanged' THEN
                v_summary := jsonb_insert(v_summary, ARRAY['roles', v_status, '-1'], v_item -> 'slug', true);
            END IF;
        END LOOP;

        -- Grants may name the roles of other modules.
        v_summary := v_summary || jsonb_build_object('role_permissions',
            jsonb_build_object('created', '[]'::jsonb));
        FOR v_item IN SELECT e FROM jsonb_array_elements(coalesce(definition -> 'role_permissions', '[]')) e LOOP
            SELECT id INTO v_role_id FROM roles WHERE slug = v_item ->> 'role_slug';
            IF v_role_id IS NULL THEN
                RAISE EXCEPTION 'ensure_entities: grant of %: no role with slug %',
                    v_item ->> 'permission_name', v_item ->> 'role_slug' USING ERRCODE = '22023';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM role_permissions rp
                            WHERE rp.role_id = v_role_id
                              AND rp.permission_name = v_item ->> 'permission_name') THEN
                PERFORM ensure_entities_row('role_permissions',
                    jsonb_build_object('role_id', v_role_id, 'permission_name', v_item -> 'permission_name'),
                    jsonb_build_object('role_id', v_role_id, 'permission_name', v_item -> 'permission_name'),
                    NULL, format('grant of %s to role %s', v_item ->> 'permission_name', v_item ->> 'role_slug'));
                v_summary := jsonb_insert(v_summary, ARRAY['role_permissions', 'created', '-1'],
                    to_jsonb((v_item ->> 'role_slug') || ':' || (v_item ->> 'permission_name')), true);
            END IF;
        END LOOP;

        -- The module's permission and default-role columns, now that the
        -- permissions and roles they name exist.
        v_row := '{}'::jsonb;
        FOREACH v_key IN ARRAY c_module_deferred LOOP
            CONTINUE WHEN NOT v_module ? v_key;
            IF v_key = ANY (c_module_role_keys) THEN
                IF v_module -> v_key = 'null'::jsonb THEN
                    v_row := v_row || jsonb_build_object(replace(v_key, '_slug', '_id'), NULL);
                ELSE
                    SELECT id INTO v_role_id FROM roles WHERE slug = v_module ->> v_key;
                    IF v_role_id IS NULL THEN
                        RAISE EXCEPTION 'ensure_entities: module %: %: no role with slug %',
                            v_module ->> 'module_name', v_key, v_module ->> v_key USING ERRCODE = '22023';
                    END IF;
                    v_row := v_row || jsonb_build_object(replace(v_key, '_slug', '_id'), v_role_id);
                END IF;
            ELSE
                v_row := v_row || jsonb_build_object(v_key, v_module -> v_key);
            END IF;
        END LOOP;
        IF v_row <> '{}'::jsonb THEN
            v_status := ensure_entities_row('modules',
                jsonb_build_object('module_name', v_module -> 'module_name'),
                v_row || jsonb_build_object('module_name', v_module -> 'module_name'),
                NULL, v_label);
            IF v_status = 'updated' AND v_summary ->> 'module' = 'unchanged' THEN
                v_summary := v_summary || jsonb_build_object('module', 'updated');
            END IF;
        END IF;
    END IF;

    -- ---------------------------------------------------------------
    -- 3. Entities, without the columns that name fields.
    -- ---------------------------------------------------------------
    FOR v_entry IN SELECT e FROM jsonb_array_elements(v_entries) e LOOP
        v_entity := v_entry -> 'entity';
        v_table := v_entity ->> 'table_name';
        SELECT * INTO v_current FROM entities WHERE table_name = v_table;

        IF NOT (v_entity ? 'fields') THEN
            -- A records-only entry: the entity must already exist.
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ensure_entities: entity % does not exist and the definition carries no schema for it (no "fields")',
                    v_table USING ERRCODE = '22023';
            END IF;
            CONTINUE;
        END IF;

        IF FOUND THEN
            -- Not additive: the old order column would be dropped, or the
            -- dictionary would let go of a table it created.
            IF v_entity ? 'order_column' AND v_current.order_column <> ''
               AND v_entity ->> 'order_column' IS DISTINCT FROM v_current.order_column THEN
                RAISE EXCEPTION 'ensure_entities: entity %: order_column cannot change from % to % (the old column would be dropped)',
                    v_table, v_current.order_column, coalesce(v_entity ->> 'order_column', 'null')
                    USING ERRCODE = '0A000';
            END IF;
            IF v_entity ? 'managed' AND v_current.managed
               AND (v_entity -> 'managed') IS DISTINCT FROM 'true'::jsonb THEN
                RAISE EXCEPTION 'ensure_entities: entity % cannot change from managed to unmanaged', v_table
                    USING ERRCODE = '0A000';
            END IF;
        ELSIF NOT (v_entity ? 'module_name') THEN
            RAISE EXCEPTION 'ensure_entities: entity % needs a module_name to be created', v_table
                USING ERRCODE = '22023';
        END IF;

        SELECT jsonb_object_agg(key, value) INTO v_row
          FROM jsonb_each(v_entity)
         WHERE key <> ALL (c_entity_deferred || c_entity_ignored || ARRAY['fields', 'module_name']);
        IF v_entity ? 'module_name' THEN
            SELECT id INTO v_module_id FROM modules WHERE module_name = v_entity ->> 'module_name';
            IF v_module_id IS NULL THEN
                RAISE EXCEPTION 'ensure_entities: entity %: no module named %',
                    v_table, v_entity ->> 'module_name' USING ERRCODE = '22023';
            END IF;
            v_row := v_row || jsonb_build_object('module_id', v_module_id);
        END IF;

        v_status := ensure_entities_row('entities',
            jsonb_build_object('table_name', v_table), v_row,
            c_entity_create_only, 'entity ' || v_table);
        IF v_status <> 'unchanged' THEN
            v_summary := jsonb_insert(v_summary, ARRAY['entities', v_status, '-1'], to_jsonb(v_table), true);
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 4. Fields, in array order. Consecutive new fields of one entity are
    --    inserted by one statement, as a hand-written migration would, so
    --    the dictionary's statement-level work (the search_vector rebuild)
    --    runs once for them and the physical column order is array order.
    -- ---------------------------------------------------------------
    FOR v_entry IN SELECT e FROM jsonb_array_elements(v_entries) e LOOP
        v_entity := v_entry -> 'entity';
        CONTINUE WHEN NOT (v_entity ? 'fields');
        v_table := v_entity ->> 'table_name';
        v_batch := '[]'::jsonb;

        FOR v_field, v_idx IN
            SELECT f, i FROM jsonb_array_elements(v_entity -> 'fields') WITH ORDINALITY AS t(f, i)
        LOOP
            v_row := v_field - c_field_ignored;
            IF EXISTS (SELECT 1 FROM fields WHERE table_name = v_table AND field_name = v_field ->> 'field_name') THEN
                -- Flush the pending inserts first, to keep array order.
                IF jsonb_array_length(v_batch) > 0 THEN
                    PERFORM ensure_entities_insert_rows('fields', v_batch);
                    PERFORM set_config('client_min_messages', current_setting('semantius.notice_level'), true);
                    FOR v_item IN SELECT b FROM jsonb_array_elements(v_batch) b LOOP
                        RAISE NOTICE 'ensure_entities: created field %.%', v_table, v_item ->> 'field_name';
                    END LOOP;
                    v_summary := jsonb_set(v_summary, ARRAY['fields', 'created'],
                        (v_summary #> ARRAY['fields', 'created'])
                        || (SELECT jsonb_agg(to_jsonb(v_table || '.' || (b ->> 'field_name')))
                              FROM jsonb_array_elements(v_batch) b));
                    v_batch := '[]'::jsonb;
                END IF;
                IF v_row ? 'ctype' AND (v_row ->> 'ctype') IS DISTINCT FROM
                   (SELECT ctype FROM fields WHERE table_name = v_table AND field_name = v_field ->> 'field_name') THEN
                    RAISE EXCEPTION 'ensure_entities: field %.%: ctype is set when a field is created and cannot change',
                        v_table, v_field ->> 'field_name' USING ERRCODE = '0A000';
                END IF;
                v_status := ensure_entities_row('fields',
                    jsonb_build_object('table_name', v_table, 'field_name', v_field -> 'field_name'),
                    v_row || jsonb_build_object('table_name', v_table),
                    c_field_create_only, format('field %s.%s', v_table, v_field ->> 'field_name'));
                IF v_status = 'updated' THEN
                    v_summary := jsonb_insert(v_summary, ARRAY['fields', 'updated', '-1'],
                        to_jsonb(v_table || '.' || (v_field ->> 'field_name')), true);
                END IF;
            ELSE
                v_batch := v_batch || jsonb_build_array(v_row || jsonb_build_object('table_name', v_table));
            END IF;
        END LOOP;
        IF jsonb_array_length(v_batch) > 0 THEN
            PERFORM ensure_entities_insert_rows('fields', v_batch);
            PERFORM set_config('client_min_messages', current_setting('semantius.notice_level'), true);
            FOR v_item IN SELECT b FROM jsonb_array_elements(v_batch) b LOOP
                RAISE NOTICE 'ensure_entities: created field %.%', v_table, v_item ->> 'field_name';
            END LOOP;
            v_summary := jsonb_set(v_summary, ARRAY['fields', 'created'],
                (v_summary #> ARRAY['fields', 'created'])
                || (SELECT jsonb_agg(to_jsonb(v_table || '.' || (b ->> 'field_name')))
                      FROM jsonb_array_elements(v_batch) b));
        END IF;

        -- Reported, never deleted.
        v_summary := jsonb_set(v_summary, ARRAY['fields_not_in_definition'],
            (v_summary -> 'fields_not_in_definition')
            || coalesce((SELECT jsonb_agg(to_jsonb(f.id) ORDER BY f.field_order, f.field_name)
                           FROM fields f
                          WHERE f.table_name = v_table
                            AND coalesce(f.ctype, '') = ''
                            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_entity -> 'fields') d
                                             WHERE d ->> 'field_name' = f.field_name)), '[]'::jsonb));
    END LOOP;

    -- ---------------------------------------------------------------
    -- 5. The entity columns that name fields.
    -- ---------------------------------------------------------------
    FOR v_entry IN SELECT e FROM jsonb_array_elements(v_entries) e LOOP
        v_entity := v_entry -> 'entity';
        CONTINUE WHEN NOT (v_entity ? 'fields');
        v_table := v_entity ->> 'table_name';
        SELECT jsonb_object_agg(key, value) INTO v_row
          FROM jsonb_each(v_entity) WHERE key = ANY (c_entity_deferred);
        CONTINUE WHEN v_row IS NULL;
        v_status := ensure_entities_row('entities',
            jsonb_build_object('table_name', v_table),
            v_row || jsonb_build_object('table_name', v_table),
            NULL, 'entity ' || v_table);
        IF v_status = 'updated'
           AND NOT (v_summary #> ARRAY['entities', 'created']) @> to_jsonb(ARRAY[v_table])
           AND NOT (v_summary #> ARRAY['entities', 'updated']) @> to_jsonb(ARRAY[v_table]) THEN
            v_summary := jsonb_insert(v_summary, ARRAY['entities', 'updated', '-1'], to_jsonb(v_table), true);
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------
    -- 6. Records, table by table in foreign-key order.
    -- ---------------------------------------------------------------
    DECLARE
        v_pending  TEXT[];
        v_done     TEXT[] := ARRAY[]::TEXT[];
        v_next     TEXT;
        v_records  JSONB;
        v_id_col   TEXT;
        v_cols     TEXT[];
        v_skip     TEXT[];
        v_unknown  TEXT;
        v_col_list TEXT;
        v_sequence TEXT;
        v_max      BIGINT;
        v_last     BIGINT;
        v_called   BOOLEAN;
    BEGIN
        SELECT array_agg(e -> 'entity' ->> 'table_name' ORDER BY i)
          INTO v_pending
          FROM jsonb_array_elements(v_entries) WITH ORDINALITY AS t(e, i)
         WHERE jsonb_array_length(coalesce(e -> 'records', '[]')) > 0;

        WHILE coalesce(array_length(v_pending, 1), 0) > 0 LOOP
            -- The first pending table whose referenced tables (among those
            -- with records here) are all written. A reference to its own
            -- table needs no order: one INSERT writes every new row, and the
            -- foreign key is checked at the end of that statement.
            SELECT p INTO v_next
              FROM unnest(v_pending) WITH ORDINALITY AS u(p, ord)
             WHERE NOT EXISTS (
                     SELECT 1 FROM fields f
                      WHERE f.table_name = p
                        AND f.format IN ('reference', 'parent')
                        AND f.reference_table <> p
                        AND f.reference_table = ANY (v_pending))
             ORDER BY ord
             LIMIT 1;
            IF v_next IS NULL THEN
                RAISE EXCEPTION 'ensure_entities: the records of % reference each other; no order writes them',
                    array_to_string(v_pending, ', ') USING ERRCODE = '22023';
            END IF;
            v_table := v_next;
            v_pending := array_remove(v_pending, v_table);

            SELECT e -> 'records' INTO v_records
              FROM jsonb_array_elements(v_entries) e
             WHERE e -> 'entity' ->> 'table_name' = v_table;
            SELECT * INTO v_current FROM entities WHERE table_name = v_table;
            v_id_col := v_current.id_column;

            -- Every record carries the same keys: an omitted key would mean
            -- "default" for a new row and "untouched" for an existing one,
            -- which a set-based write cannot tell apart per row.
            SELECT array_agg(k ORDER BY k) INTO v_cols
              FROM jsonb_object_keys(v_records -> 0) AS k;
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_records) r
                        WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r) AS k)
                              IS DISTINCT FROM v_cols) THEN
                RAISE EXCEPTION 'ensure_entities: the records of % do not all carry the same keys', v_table
                    USING ERRCODE = '22023';
            END IF;
            IF NOT (v_id_col = ANY (v_cols)) THEN
                RAISE EXCEPTION 'ensure_entities: the records of % carry no %, the id column', v_table, v_id_col
                    USING ERRCODE = '22023';
            END IF;
            SELECT string_agg(c, ', ') INTO v_unknown FROM unnest(v_cols) AS c
             WHERE c <> v_id_col
               AND NOT EXISTS (SELECT 1 FROM fields f WHERE f.table_name = v_table AND f.field_name = c);
            IF v_unknown IS NOT NULL THEN
                RAISE EXCEPTION 'ensure_entities: records of %: % has no field %', v_table, v_table, v_unknown
                    USING ERRCODE = '22023';
            END IF;

            -- The platform sets these; a value in the file is not written.
            SELECT array_agg(x) INTO v_skip FROM (
                SELECT f.field_name AS x FROM fields f WHERE f.table_name = v_table AND f.ctype = 'audit'
                UNION
                SELECT c ->> 'name' FROM jsonb_array_elements(v_current.computed_fields) c
            ) s;
            v_cols := ARRAY(SELECT c FROM unnest(v_cols) AS c
                             WHERE c = v_id_col OR c <> ALL (coalesce(v_skip, ARRAY[]::TEXT[]))
                             ORDER BY c);
            SELECT string_agg(format('%I', c), ', ' ORDER BY c) INTO v_col_list FROM unnest(v_cols) AS c;

            EXECUTE format(
                'INSERT INTO public.%1$I (%2$s)
                 SELECT %3$s FROM jsonb_populate_recordset(NULL::public.%1$I, $1) WITH ORDINALITY AS r
                  WHERE NOT EXISTS (SELECT 1 FROM public.%1$I x WHERE x.%4$I = r.%4$I)
                  ORDER BY r.ordinality',
                v_table, v_col_list,
                (SELECT string_agg(format('r.%I', c), ', ' ORDER BY c) FROM unnest(v_cols) AS c),
                v_id_col)
            USING v_records;
            GET DIAGNOSTICS v_n = ROW_COUNT;

            v_m := 0;
            IF array_length(v_cols, 1) > 1 THEN
                EXECUTE format(
                    'UPDATE public.%1$I x SET %2$s
                       FROM jsonb_populate_recordset(NULL::public.%1$I, $1) r
                      WHERE x.%3$I = r.%3$I
                        AND jsonb_build_array(%4$s) IS DISTINCT FROM jsonb_build_array(%5$s)',
                    v_table,
                    (SELECT string_agg(format('%1$I = r.%1$I', c), ', ' ORDER BY c) FROM unnest(v_cols) AS c WHERE c <> v_id_col),
                    v_id_col,
                    (SELECT string_agg(format('x.%I', c), ', ' ORDER BY c) FROM unnest(v_cols) AS c WHERE c <> v_id_col),
                    (SELECT string_agg(format('r.%I', c), ', ' ORDER BY c) FROM unnest(v_cols) AS c WHERE c <> v_id_col))
                USING v_records;
                GET DIAGNOSTICS v_m = ROW_COUNT;
            END IF;

            IF v_n > 0 OR v_m > 0 THEN
                PERFORM set_config('client_min_messages', current_setting('semantius.notice_level'), true);
                RAISE NOTICE 'ensure_entities: records of %: % inserted, % updated', v_table, v_n, v_m;
            END IF;
            v_summary := jsonb_set(v_summary, ARRAY['records', v_table],
                jsonb_build_object('inserted', v_n, 'updated', v_m));

            -- Explicit ids leave the id sequence behind them: move it past the
            -- highest id, never lower (the rule public.fix_id_sequence applies).
            IF EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = format('public.%I', v_table)::regclass
                          AND a.attname = v_id_col AND a.attnum > 0 AND NOT a.attisdropped) THEN
                v_sequence := pg_get_serial_sequence(format('public.%I', v_table), v_id_col);
                IF v_sequence IS NOT NULL THEN
                    EXECUTE format('SELECT max(%I)::bigint FROM public.%I', v_id_col, v_table) INTO v_max;
                    EXECUTE format('SELECT last_value, is_called FROM %s', v_sequence) INTO v_last, v_called;
                    IF coalesce(v_max, 0) + 1 > (CASE WHEN v_called THEN v_last + 1 ELSE v_last END) THEN
                        PERFORM setval(v_sequence, v_max, true);
                    END IF;
                END IF;
            END IF;
            v_done := v_done || v_table;
        END LOOP;
    END;

    RETURN v_summary;
END;
$fn$;

COMMENT ON FUNCTION public.ensure_entities(JSONB) IS
'Applies a declarative entity definition (the semantius-cli export format, version 1): makes the listed module sections, entities, fields and records exist as described. Creates what is missing, updates only what differs, never deletes, never upserts metadata. Returns a summary of what it created and updated and which fields the definition does not list; raises one NOTICE per change. Run by the migration runners for every .jsonc migration file.';

REVOKE EXECUTE ON FUNCTION public.ensure_entities(JSONB) FROM PUBLIC;
