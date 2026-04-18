-- Test plural column auto-assignment
BEGIN;

SELECT plan(2);

-- =====================================================
-- TEST: Verify plural matches table_name for all tables
-- =====================================================

-- Test 1: customers_test table (inserted WITHOUT plural value)
-- Should have plural = 'customers_test' (auto-set from table_name)
SELECT is(
    (SELECT plural FROM entities WHERE table_name = 'customers_test'),
    'customers_test',
    'customers_test table should have plural = "customers_test" (auto-set from table_name)'
);

-- Test 2: employees_test table (inserted WITH wrong plural value 'wrongplural')
-- Should have plural = 'employees_test' (user input ignored, auto-set from table_name)
SELECT is(
    (SELECT plural FROM entities WHERE table_name = 'employees_test'),
    'employees_test',
    'employees_test table should have plural = "employees_test" (wrong user input ignored)'
);


SELECT * FROM finish();
ROLLBACK;
