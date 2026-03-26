-- Test public.get_module_cubes() function
BEGIN;

SELECT plan(8);

select authenticate_as('user1');

-- =====================================================
-- TEST: get_module_cubes() returns schemas for the cube entities
-- =====================================================
-- CRM module (1001) has: customers_test, regions_test
-- customers_test references regions_test (already in CRM)
-- Expected cube for CRM: customers_test, regions_test (2 schemas)

-- Test 1: get_module_cubes() returns at least one row for a known module
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cubes('CRM')),
    'get_module_cubes(CRM) should return at least one row'
);

-- Test 2: CRM module cube contains schema for customers_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('CRM') AS s
        WHERE s->'table'->>'table_name' = 'customers_test'
    ),
    'CRM module cube should include schema for customers_test'
);

-- Test 3: CRM module cube contains schema for regions_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('CRM') AS s
        WHERE s->'table'->>'table_name' = 'regions_test'
    ),
    'CRM module cube should include schema for regions_test (direct entity)'
);

-- Test 4: CRM module cube returns exactly 2 schemas
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('CRM')),
    2,
    'CRM module cube should have exactly 2 schemas (customers_test and regions_test)'
);

-- Test 5: HR module cube contains schema for employees_test
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('HR') AS s
        WHERE s->'table'->>'table_name' = 'employees_test'
    ),
    'HR module cube should include schema for employees_test'
);

-- Test 6: HR module cube contains schema for departments (referenced by employees_test)
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_module_cubes('HR') AS s
        WHERE s->'table'->>'table_name' = 'departments'
    ),
    'HR module cube should include schema for departments'
);

-- Test 7: get_module_cubes() returns empty set for unknown module
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('NONEXISTENT_MODULE')),
    0,
    'get_module_cubes() should return empty set for unknown module name'
);

-- Test 8: Results are unique (no duplicates)
-- customers_test references regions_test which is also in CRM — should only appear once
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('CRM') AS s
     WHERE s->'table'->>'table_name' = 'regions_test'),
    1,
    'regions_test should appear exactly once in CRM cube even though it is referenced'
);

SELECT * FROM finish();
ROLLBACK;
