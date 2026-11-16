-- Test security policies: RLS and function permissions
--
-- The three checks below are scoped differently on purpose, and the scopes are
-- not an oversight to be tidied up:
--   2.1 (RLS) covers public and rbac. It cannot cover common: common._cache has
--       RLS enabled with no policies BY DESIGN (0040_cache.sql), which is how a table is
--       made unreachable through the Data API, and 2.1 reads that shape as a
--       failure.
--   2.2 (PUBLIC EXECUTE) covers public, rbac, common and audit - every schema
--       whose functions this project writes. PostgreSQL grants EXECUTE to PUBLIC
--       on every new function and the schema-wide ALTER DEFAULT PRIVILEGES in
--       0020_settings.once.sql does not stop it (see the comment there), so an explicit REVOKE is
--       the only defense and this is what proves one was written. `pgmq` is
--       excluded although 0310_pgmq.once.sql creates its functions here too: they are vendored
--       upstream code kept byte-identical to it, they are not reachable from
--       PostgREST, which exposes `public` only, and what they expose to a
--       DB-only caller is queue names, metrics and topic bindings. Revisit if
--       `pgmq` is ever exposed or the request role gains SELECT on a queue
--       table.
--   2.3 (SECURITY DEFINER must call rbac.uid()) covers public and rbac. It
--       cannot cover common or audit: the five cache functions,
--       refresh_schema_cache, enable_tracking, disable_tracking,
--       primary_key_columns and log_ddl_event are all definers that legitimately
--       have no identity to check, because they run before or beneath any
--       request. Widening it would mean adding every one of them to the
--       exclusion list, which is the thing 2.3 exists to avoid.
BEGIN;

SELECT plan(12);

-- =====================================================
-- TEST 2.1: Check for tables not using RLS
-- =====================================================
-- All tables in public and rbac schemas should have RLS enabled
-- Get a comma separated string of all tables not using RLS - expect to be empty

SELECT is(
    (
        SELECT string_agg(schemaname || '.' || tablename, ', ' ORDER BY schemaname, tablename)
        FROM (
            SELECT DISTINCT
                n.nspname AS schemaname,
                c.relname AS tablename
            FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname IN ('public', 'rbac')
            AND c.relkind = 'r'  -- regular tables only
            AND (
                -- RLS is not enabled on the table
                NOT c.relrowsecurity
                -- OR no RLS policies exist for the table
                OR NOT EXISTS (
                    SELECT 1
                    FROM pg_policies pp
                    WHERE pp.schemaname = n.nspname
                    AND pp.tablename = c.relname
                )
            )
        ) AS tables_without_rls
    ),
    NULL::text,
    'All tables in public and rbac schemas should have RLS enabled with policies'
);

-- =====================================================
-- TEST 2.2: Check for functions executable by public
-- =====================================================
-- Get a comma separated list of all function names in the four schemas this
-- project defines functions in, where the function is executable by public.
-- The list should be empty - all functions should have REVOKE EXECUTE FROM PUBLIC

SELECT is(
    (
        SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname IN ('public', 'rbac', 'common', 'audit')
        AND pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE')
        -- pgcrypto extension functions are intentionally public
        AND NOT EXISTS (
            SELECT 1 FROM pg_extension e
            JOIN pg_depend d ON d.refobjid = e.oid AND d.classid = 'pg_catalog.pg_proc'::regclass AND d.objid = p.oid
            WHERE e.extname = 'pgcrypto'
        )
    ),
    NULL::text,
    'No functions in public, rbac, common and audit schemas should be executable by public role'
);

-- =====================================================
-- TEST 2.3: All SECURITY DEFINER functions must call rbac.uid()
-- =====================================================
-- Every non-trigger SECURITY DEFINER function must call rbac.uid()
-- directly in its source code. No allowlists, no indirect chain assumptions.
-- rbac.uid() is STABLE, but that never memoizes a PL/pgSQL call: every call
-- costs one full claims validation and one _settings read, which is why the
-- hot paths (rbac.has_permission, has_any_permission, user_id,
-- ensure_context_initialized) carry a warm test of their own instead of
-- calling this guard on every check.
-- rbac.uid itself is excluded.
-- Trigger functions are excluded (invoked by the DB engine, not by users).

SELECT is(
    (
        SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname IN ('public', 'rbac')
        AND p.prosecdef = true                          -- SECURITY DEFINER only
        AND p.prorettype != 'trigger'::regtype          -- exclude trigger functions
        AND p.proname != 'uid'                          -- exclude uid itself
        AND p.prosrc NOT LIKE '%rbac.uid()%'            -- must call rbac.uid() directly
        -- Exclude helper functions called by triggers during migrations (no JWT context).
        -- These are NOT trigger functions themselves (they return VOID/BOOLEAN, not trigger)
        -- but are invoked by trigger functions during DDL migrations.
        AND p.proname NOT IN (
            'update_search_vector_column',
            'update_table_searchable_flag',
            'apply_field_searchable_change',
            'update_table_is_child_flag',
            'validate_api_key',
            'apply_field_ddl',
            'build_record_logic_trigger',
            'build_select_rule_policy',
            'raci_install_or_drop_emit_trigger',
            'raci_install_or_drop_gate_trigger',
            'rebuild_entity_label_functions',
            -- Counts the enabled Administrators for rbac.assert_administrator_remains.
            -- It must answer for a session that carries no claims at all - the
            -- superuser repair connection the guard exempts is exactly that - so
            -- rbac.uid() here would raise on the one caller that has to get
            -- through, and cost a claims validation on every guarded statement
            -- for the rest.
            'count_enabled_administrators'
        )
        -- Exclude generated select_rule_* functions (called from RLS policies, not by users directly)
        AND p.proname NOT LIKE 'select\_rule\_%'
    ),
    NULL::text,
    'All non-trigger SECURITY DEFINER functions must call rbac.uid()'
);

-- =====================================================
-- TEST 2.4: Privileges the request role must not hold
-- =====================================================
-- Six catalog facts, asserted here rather than only through behavior because
-- a grant comes back by accident - a new GRANT ... ON ALL, a schema-wide default
-- privilege, a vendor bump - long after the behavior test that covered it was
-- written, and this file is where a reviewer looks.

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'common.cache_get(text)', 'EXECUTE'),
    'the request role cannot call the cache primitives (common.cache_get)'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'public.validate_api_key(text)', 'EXECUTE'),
    'the request role cannot run the API-key validator'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'common.refresh_schema_cache()', 'EXECUTE'),
    'the request role cannot make PostgREST reload its schema cache'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'rbac.upsert_user_from_jwt(text, text, text, text, text)', 'EXECUTE'),
    'the request role cannot provision or update an arbitrary principal'
);

-- The audit tables are append-only from the outside: the five SECURITY DEFINER
-- trigger functions write them, nothing else may.
SELECT ok(
    NOT pg_catalog.has_table_privilege('semantius_user', 'public.audit_record_logs', 'INSERT')
    AND NOT pg_catalog.has_table_privilege('semantius_user', 'public.audit_record_logs', 'UPDATE'),
    'the request role can neither insert nor update audit_record_logs'
);

SELECT ok(
    NOT pg_catalog.has_table_privilege('semantius_user', 'public.audit_ddl_logs', 'INSERT')
    AND NOT pg_catalog.has_table_privilege('semantius_user', 'public.audit_ddl_logs', 'UPDATE'),
    'the request role can neither insert nor update audit_ddl_logs'
);

-- =====================================================
-- TEST 2.5: Every pinned search_path ends in pg_temp
-- =====================================================
-- PostgreSQL looks a table name up in the session's temporary schema before
-- any other, unless the path names pg_temp itself, and the request role may
-- create temporary tables. A function whose path leaves pg_temp out reads the
-- caller's temporary table in place of the dictionary's: rbac's own lookup of
-- `users` would take the caller for whoever a temporary `users` says, an
-- administrator included (0537_test_dynamic_sql_values.sql shows it). Listed
-- last, pg_temp is searched only after every schema of the dictionary.
-- 0910_test_no_unsafe_functions.sql asserts that every function pins a path;
-- this asserts what the path has to end in. The empty path belongs to the
-- functions that qualify every name. Extension-owned functions are excluded.

SELECT is(
    (
        SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text)
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        CROSS JOIN LATERAL (
            SELECT substring(c FROM 'search_path=(.*)') AS path
            FROM unnest(coalesce(p.proconfig, '{}')) AS c
            WHERE c LIKE 'search_path=%'
        ) s
        WHERE n.nspname IN ('public', 'rbac', 'common', 'audit')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
        AND s.path NOT IN ('', '""')                    -- the empty path: every name is qualified
        AND s.path !~ '(^|, )pg_temp$'                  -- pg_temp, and last
    ),
    NULL::text,
    'Every function that pins a search_path lists pg_temp last'
);

-- =====================================================
-- TEST 2.6: Every function that builds SQL has been audited
-- =====================================================
-- A function that runs EXECUTE, or builds text with format(), quote_ident(),
-- quote_literal(), quote_nullable() or dd_dollar_quote(), may put a value a
-- caller wrote into a statement. docs/dynamic-sql-audit.md lists every such
-- value, how it gets there and which test pins it, and the hostile-value
-- tests (0535, 0530, 0537) cover what it lists. A function that is new, or
-- that starts to build SQL, is in none of them until somebody reads it. So it
-- fails here, under its name, until it has its rows on that page and its
-- name below.
--
-- The scan reads the body without its `--` comments, which mention EXECUTE and
-- format in prose. Functions the dictionary generates per entity carry
-- "Generated by" in their comment and are left out: their generator is on the
-- list, and the page audits what the generator writes. Extension-owned and
-- pgmq functions are left out as in TEST 2.2; pgmq is vendored and audited on
-- the page as it stands.
--
-- The second list holds the functions whose format() builds the name of a rule
-- for a message or a hint and no SQL; they have no row on the page.
--
-- The second assertion keeps the list honest: a name that no longer exists, or
-- no longer builds SQL, is taken off it.

CREATE TEMP TABLE sec_sql_builders (name TEXT PRIMARY KEY, builds_sql BOOLEAN NOT NULL);
INSERT INTO sec_sql_builders (name, builds_sql)
SELECT n, TRUE FROM unnest(ARRAY[
            'audit.disable_tracking', 'audit.enable_tracking', 'common.has_a_guard',
            'common.is_a_part_missing', 'common.row_move_mark', 'common.typeid_assign',
            'public.add_dd_field', 'public.apply_field_ddl', 'public.auto_set_order_value',
            'public.build_record_logic_trigger', 'public.build_select_rule_policy', 'public.check_entity_family',
            'public.computed_backfill', 'public.create_dd_table', 'public.create_entity_policies',
            'public.dd_add_required_check', 'public.dd_backfill_mute', 'public.dd_build_family_view',
            'public.dd_build_is_a_dispatch', 'public.dd_build_record_write', 'public.dd_build_view_write',
            'public.dd_check_enum_values_cover_rows', 'public.dd_check_family_dependents', 'public.dd_check_id_column',
            'public.dd_constraint_exists', 'public.dd_dispatch_case', 'public.dd_drop_own_index',
            'public.dd_drop_required_check', 'public.dd_family_columns', 'public.dd_field_has_missing',
            'public.dd_id_column_ddl', 'public.dd_index_name_free', 'public.dd_install_id_triggers',
            'public.dd_install_key_rule_checks', 'public.dd_install_missing_checks', 'public.dd_key_kept_sql',
            'public.dd_key_prefix_sql', 'public.dd_refresh_family', 'public.dd_relation_has_rows',
            'public.dd_replace_enum_check', 'public.dd_required_check_expr', 'public.dd_required_default_ok',
            'public.dd_required_test', 'public.dd_sync_typeid_prefix', 'public.dd_typeid_trigger_args',
            'public.dd_unique_predicate', 'public.delete_dd_field', 'public.delete_dd_table',
            'public.enable_dd_table', 'public.ensure_entities', 'public.ensure_entities_insert_rows',
            'public.ensure_entities_row', 'public.field_data_type', 'public.fix_id_sequence',
            'public.get_record_by_id', 'public.handle_entity_order_column', 'public.manage_audit_log',
            'public.manage_record_logic_trigger', 'public.manage_select_rule_policy', 'public.queue_event_after_delete',
            'public.queue_event_after_insert', 'public.quote_default_value', 'public.raci_sync_triggers',
            'public.rebuild_entity_label_functions', 'public.rename_dd_table', 'public.rollup_backfill',
            'public.rollup_build_guard', 'public.rollup_build_link', 'public.rollup_create_function',
            'public.rollup_definition', 'public.rollup_filter_column', 'public.rollup_filter_cond',
            'public.rollup_filter_date_arg', 'public.rollup_filter_date_op', 'public.rollup_filter_literal',
            'public.rollup_filter_operand', 'public.rollup_filter_operands', 'public.rollup_rename_field_refs',
            'public.rollup_sync_field', 'public.rollup_value_sql', 'public.update_dd_field',
            'public.update_dd_table_comment', 'public.update_entity_policies', 'public.update_search_vector_column',
            'public.validate_field_rename_and_format', 'public.zz_rollup_entity_change', 'public.zz_rollup_entity_delete'
        ]) AS n
UNION ALL
SELECT n, FALSE FROM unnest(ARRAY[
            'public.check_entity_rules', 'public.dd_rule_naming_field'
        ]) AS n;

CREATE TEMP VIEW sec_sql_scan AS
SELECT DISTINCT n.nspname || '.' || p.proname AS name
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname IN ('public', 'rbac', 'common', 'audit')
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
   AND coalesce(obj_description(p.oid, 'pg_proc'), '') !~* 'generated by'
   AND regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
       ~* '\m(EXECUTE|format\s*\(|quote_ident\s*\(|quote_literal\s*\(|quote_nullable\s*\(|dd_dollar_quote\s*\()';

SELECT is(
    (SELECT string_agg(s.name, ', ' ORDER BY s.name)
       FROM sec_sql_scan s
      WHERE NOT EXISTS (SELECT 1 FROM sec_sql_builders b WHERE b.name = s.name)),
    NULL::text,
    'Every function that builds SQL at run time is on the audited list (docs/dynamic-sql-audit.md)'
);

SELECT is(
    (SELECT string_agg(b.name, ', ' ORDER BY b.name)
       FROM sec_sql_builders b
      WHERE NOT EXISTS (SELECT 1 FROM sec_sql_scan s WHERE s.name = b.name)),
    NULL::text,
    'Every function on the audited list still exists and still builds SQL'
);

SELECT * FROM finish();
ROLLBACK;
