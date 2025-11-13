-- Test plural column auto-assignment
BEGIN;

SELECT plan(4);

-- =====================================================
-- TEST: Verify plural matches table_name for all tables
-- =====================================================

-- Test 1: customers table (inserted WITHOUT plural value)
-- Should have plural = 'customers' (auto-set from table_name)
SELECT is(
    (SELECT plural FROM tables WHERE table_name = 'customers'),
    'customers',
    'customers table should have plural = "customers" (auto-set from table_name)'
);

-- Test 2: employees table (inserted WITH wrong plural value 'wrongplural')
-- Should have plural = 'employees' (user input ignored, auto-set from table_name)
SELECT is(
    (SELECT plural FROM tables WHERE table_name = 'employees'),
    'employees',
    'employees table should have plural = "employees" (wrong user input ignored)'
);

-- Test 3: products table (inserted WITH correct plural value 'products')
-- Should have plural = 'products' (trigger ensures it matches table_name)
SELECT is(
    (SELECT plural FROM tables WHERE table_name = 'products'),
    'products',
    'products table should have plural = "products" (correct value maintained)'
);

-- Test 4: UPDATE products table with wrong plural value
-- The trigger should ignore the update and keep plural = 'products'
SELECT authenticate_as('user3'); -- user3 is admin with permission to update

UPDATE tables 
SET plural = 'wrongupdatevalue'
WHERE table_name = 'products';

SELECT is(
    (SELECT plural FROM tables WHERE table_name = 'products'),
    'products',
    'products table should still have plural = "products" after UPDATE with wrong value (ignored by trigger)'
);

SELECT * FROM finish();
ROLLBACK;
