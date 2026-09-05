-- Test security policies: RLS and function permissions
--
-- The three checks below are scoped differently on purpose, and the scopes are
-- not an oversight to be tidied up:
--   2.1 (RLS) covers public and rbac. It cannot cover common: common._cache has
--       RLS enabled with no policies BY DESIGN (0012), which is how a table is
--       made unreachable through the Data API, and 2.1 reads that shape as a
--       failure.
--   2.2 (PUBLIC EXECUTE) covers public, rbac, common and audit. Every schema
--       this project creates functions in belongs here: PostgreSQL grants
--       EXECUTE to PUBLIC on every new function and the schema-wide ALTER
--       DEFAULT PRIVILEGES in 0010 does not stop it (see the comment there), so
--       an explicit REVOKE is the only defense and this is what proves one was
--       written.
--   2.3 (SECURITY DEFINER must call rbac.uid()) covers public and rbac. It
--       cannot cover common or audit: the cache functions, refresh_schema_cache
--       and audit.enable_tracking are definers that legitimately have no
--       identity to check, because they run before or beneath any request.
--       Widening it would mean adding all of them to the exclusion list, which
--       is the thing 2.3 exists to avoid.
BEGIN;

SELECT plan(9);

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
        -- public.validate_api_key is intentionally public executable
        AND NOT (n.nspname = 'public' AND p.proname = 'validate_api_key')
    ),
    NULL::text,
    'No functions in public, rbac, common and audit schemas should be executable by public role'
);

-- =====================================================
-- TEST 2.3: All SECURITY DEFINER functions must call rbac.uid()
-- =====================================================
-- Every non-trigger SECURITY DEFINER function must call rbac.uid()
-- directly in its source code. No allowlists, no indirect chain assumptions.
-- rbac.uid() is STABLE and cached per transaction so the cost is zero.
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
            'validate_permission_exists',
            'validate_api_key',
            'apply_field_ddl',
            'build_record_logic_trigger',
            'build_select_rule_policy',
            'raci_install_or_drop_emit_trigger',
            'rebuild_entity_label_functions'
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
-- Six catalog facts, each of which was true in the other direction until
-- 2026-09-05. They are asserted here rather than only through behavior because
-- a grant is restored by accident - a new GRANT ... ON ALL, a schema-wide
-- default privilege, a vendor bump - long after the behavior test that once
-- covered it was written, and this file is where a reviewer looks.

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'common.cache_get(text)', 'EXECUTE'),
    'the request role cannot call the cache primitives (common.cache_get)'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'common.refresh_schema_cache()', 'EXECUTE'),
    'the request role cannot make PostgREST reload its schema cache'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'rbac.upsert_user_from_jwt(text, text, text, text, text)', 'EXECUTE'),
    'the request role cannot provision or update an arbitrary principal'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'rbac.validate_permission_exists(text)', 'EXECUTE'),
    'the request role cannot probe the permission catalog through a definer'
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

SELECT * FROM finish();
ROLLBACK;
