-- Test security policies: RLS and function permissions
BEGIN;

SELECT plan(2);

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
-- Get a comma separated list of all function names in public and rbac schema
-- where the function is executable by public
-- The list should be empty but in the current iteration expect this test to fail,
-- we will fix it in a future iteration

SELECT is(
    (
        SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname IN ('public', 'rbac')
        AND pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE')
    ),
    NULL::text,
    'No functions in public and rbac schemas should be executable by public role (expected to fail in current iteration)'
);

SELECT * FROM finish();
ROLLBACK;
