-- Test public.get_module_cubes() function
BEGIN;

SELECT plan(9);

select authenticate_as('user1');

-- =====================================================
-- TEST: get_module_cubes() returns schemas for the cube entities
-- =====================================================
-- CRM module (1001) has: customers_test, regions_test
-- customers_test references regions_test (already in CRM)
-- Expected cube for CRM: customers_test, regions_test (2 schemas)

-- Test 1: get_module_cubes() returns at least one row for a known module (slug-based lookup)
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cubes('crm')),
    'get_module_cubes(''crm'') should return at least one row'
);

-- Test 2: CRM module cube contains schema for customers_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('crm') AS s
        WHERE s->'table'->>'table_name' = 'customers_test'
    ),
    'CRM module cube should include schema for customers_test'
);

-- Test 3: CRM module cube contains schema for regions_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('crm') AS s
        WHERE s->'table'->>'table_name' = 'regions_test'
    ),
    'CRM module cube should include schema for regions_test (direct entity)'
);

-- Test 4: CRM module cube returns exactly 2 schemas
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('crm')),
    2,
    'CRM module cube should have exactly 2 schemas (customers_test and regions_test)'
);

-- Test 5: HR module cube contains schema for employees_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('hr') AS s
        WHERE s->'table'->>'table_name' = 'employees_test'
    ),
    'HR module cube should include schema for employees_test'
);

-- Test 6: HR module cube contains schema for departments (referenced by employees_test)
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('hr') AS s
        WHERE s->'table'->>'table_name' = 'departments'
    ),
    'HR module cube should include schema for departments'
);

-- Test 7: get_module_cubes() returns empty set for unknown module slug
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('nonexistent_module')),
    0,
    'get_module_cubes() should return empty set for unknown module slug'
);

-- Test 7b: get_module_cubes() does NOT match by module_name — only by module_slug.
-- The 'HR' module has slug 'hr'; passing 'HR' (the name) must return no rows.
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('HR')),
    0,
    'get_module_cubes(''HR'') should return 0 rows because lookup is by slug, not name'
);

-- Test 8: Results are unique (no duplicates)
-- customers_test references regions_test which is also in CRM — should only appear once
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('crm') AS s
     WHERE s->'table'->>'table_name' = 'regions_test'),
    1,
    'regions_test should appear exactly once in CRM cube even though it is referenced'
);

SELECT * FROM finish();
ROLLBACK;
