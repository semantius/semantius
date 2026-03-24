-- Test public.get_module_cube() function
BEGIN;

SELECT plan(8);

-- =====================================================
-- TEST: get_module_cube() returns correct entities
-- =====================================================
-- CRM module (1001) has: customers_test, regions_test
-- customers_test references regions_test (already in CRM)
-- Expected cube for CRM: customers_test, regions_test

-- Test 1: get_module_cube() returns a non-empty result for a known module
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cube('CRM')),
    'get_module_cube(CRM) should return at least one row'
);

-- Test 2: CRM module cube contains customers_test
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cube('CRM') WHERE get_module_cube = 'customers_test'),
    'CRM module cube should include customers_test'
);

-- Test 3: CRM module cube contains regions_test
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cube('CRM') WHERE get_module_cube = 'regions_test'),
    'CRM module cube should include regions_test (direct entity)'
);

-- Test 4: CRM module cube returns exactly 2 entities
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cube('CRM')),
    2,
    'CRM module cube should have exactly 2 entities (customers_test and regions_test)'
);

-- Test 5: HR module cube contains employees_test
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cube('HR') WHERE get_module_cube = 'employees_test'),
    'HR module cube should include employees_test'
);

-- Test 6: HR module cube contains departments (referenced by employees_test)
SELECT ok(
    EXISTS (SELECT 1 FROM public.get_module_cube('HR') WHERE get_module_cube = 'departments'),
    'HR module cube should include departments'
);

-- Test 7: get_module_cube() returns empty set for unknown module
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cube('NONEXISTENT_MODULE')),
    0,
    'get_module_cube() should return empty set for unknown module name'
);

-- Test 8: Results are unique (no duplicates)
-- customers_test references regions_test which is also in CRM — should only appear once
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cube('CRM') WHERE get_module_cube = 'regions_test'),
    1,
    'regions_test should appear exactly once in CRM cube even though it is referenced'
);

SELECT * FROM finish();
ROLLBACK;
