-- Test plural column auto-assignment
BEGIN;

SELECT plan(4);

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

-- Test 3: products_test table (inserted WITH correct plural value 'products_test')
-- Should have plural = 'products_test' (trigger ensures it matches table_name)
SELECT is(
    (SELECT plural FROM entities WHERE table_name = 'products_test'),
    'products_test',
    'products_test table should have plural = "products_test" (correct value maintained)'
);

-- Test 4: UPDATE products_test table with wrong plural value
-- The trigger should ignore the update and keep plural = 'products_test'
SELECT authenticate_as('user3'); -- user3 is admin with permission to update

UPDATE entities 
SET plural = 'wrongupdatevalue'
WHERE table_name = 'products_test';

SELECT is(
    (SELECT plural FROM entities WHERE table_name = 'products_test'),
    'products_test',
    'products_test table should still have plural = "products_test" after UPDATE with wrong value (ignored by trigger)'
);

SELECT * FROM finish();
ROLLBACK;
