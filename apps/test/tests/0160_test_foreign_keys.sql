-- Test foreign key functionality
BEGIN;

SELECT plan(21);

-- =====================================================
-- TEST: Foreign key constraints are created
-- =====================================================
select authenticate_as('user1');

-- Test that customers_test.region_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'customers_test_region_id_fkey'
        AND conrelid = 'customers_test'::regclass
    ),
    'Foreign key constraint customers_test_region_id_fkey should exist'
);

-- Test that employees_test.department_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'employees_test_department_id_fkey'
        AND conrelid = 'employees_test'::regclass
    ),
    'Foreign key constraint employees_test_department_id_fkey should exist'
);

-- Test that indexes are created for foreign key columns
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'customers_test'
        AND indexname = 'idx_customers_test_region_id'
    ),
    'Index idx_customers_test_region_id should exist'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'employees_test'
        AND indexname = 'idx_employees_test_department_id'
    ),
    'Index idx_employees_test_department_id should exist'
);

-- =====================================================
-- TEST: Valid references can be inserted
-- =====================================================

-- Switch to user2 (has sales:manage) to insert test customers_test
select authenticate_as('user2');

-- Test inserting a customer with a valid region_id
SELECT lives_ok(
    $$
    INSERT INTO customers_test (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('Test Customer', 'test@example.com', '+1-555-0199', 'Test Corp', 'active', 0, 1)
    $$,
    'Should be able to insert customer with valid region_id'
);

-- Switch to admin for employee tests
select authenticate_as('user3');

-- Test inserting an employee with a valid department_id
SELECT lives_ok(
    $$
    INSERT INTO employees_test (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('Test Employee', 'test.employee@company.com', 1, 'Test Position', '2023-01-01', 50000, TRUE)
    $$,
    'Should be able to insert employee with valid department_id'
);

-- =====================================================
-- TEST: Invalid references are rejected
-- =====================================================

-- Switch to user2 for customer tests
select authenticate_as('user2');

-- Test that inserting a customer with invalid region_id fails
SELECT throws_ok(
    $$
    INSERT INTO customers_test (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('Invalid Customer', 'invalid@example.com', '+1-555-0198', 'Invalid Corp', 'active', 0, 9999)
    $$,
    '23503',
    NULL,
    'Should not be able to insert customer with invalid region_id'
);

-- Switch to admin for employee tests
select authenticate_as('user3');

-- Test that inserting an employee with invalid department_id fails
SELECT throws_ok(
    $$
    INSERT INTO employees_test (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('Invalid Employee', 'invalid.employee@company.com', 9999, 'Invalid Position', '2023-01-01', 50000, TRUE)
    $$,
    '23503',
    NULL,
    'Should not be able to insert employee with invalid department_id'
);

-- =====================================================
-- TEST: NULL values are allowed for nullable foreign keys
-- =====================================================

-- Switch to user2 for customer tests
select authenticate_as('user2');

-- Test inserting a customer with NULL region_id (region_id is nullable)
SELECT lives_ok(
    $$
    INSERT INTO customers_test (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('No Region Customer', 'noregion@example.com', '+1-555-0197', 'No Region Corp', 'active', 0, NULL)
    $$,
    'Should be able to insert customer with NULL region_id (nullable)'
);

-- =====================================================
-- TEST: NULL values are allowed for reference fields (all references are nullable)
-- =====================================================

-- Switch to admin for employee tests
select authenticate_as('user3');

-- Test that inserting an employee with NULL department_id succeeds (reference fields are nullable)
SELECT lives_ok(
    $$
    INSERT INTO employees_test (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('No Dept Employee', 'nodept.employee@company.com', NULL, 'No Dept Position', '2023-01-01', 50000, TRUE)
    $$,
    'Should be able to insert employee with NULL department_id (reference fields are nullable)'
);

-- Clean up
DELETE FROM employees_test WHERE full_name = 'No Dept Employee';

-- =====================================================
-- TEST: ON DELETE RESTRICT behavior for employees_test-departments
-- =====================================================

-- Try to delete a department that has employees_test (should fail due to RESTRICT)
SELECT throws_ok(
    $$
    DELETE FROM departments WHERE id = 1
    $$,
    '23503',
    NULL,
    'Should not be able to delete department with existing employees_test (RESTRICT)'
);

-- Verify the department still exists
SELECT ok(
    EXISTS (SELECT 1 FROM departments WHERE id = 1),
    'Department should still exist after failed delete attempt'
);

-- Delete the test employee first, then delete should succeed
DELETE FROM employees_test WHERE email = 'test.employee@company.com';

SELECT lives_ok(
    $$
    INSERT INTO departments (id, department_name, code, description, budget)
    VALUES (99, 'Test Department', 'TEST', 'Test department for deletion', 0.0)
    $$,
    'Should be able to insert test department'
);

SELECT lives_ok(
    $$
    DELETE FROM departments WHERE id = 99
    $$,
    'Should be able to delete department without employees_test'
);

-- =====================================================
-- TEST: ON DELETE RESTRICT behavior for customers_test-regions_test (default)
-- =====================================================

-- Switch to user2 who has sales:manage permission
select authenticate_as('user2');

-- Try to delete a region that has customers_test (should fail due to RESTRICT)
SELECT throws_ok(
    $$
    DELETE FROM regions_test WHERE id = 1
    $$,
    '23503',
    NULL,
    'Should not be able to delete region with existing customers_test (RESTRICT)'
);

-- Verify the region still exists
SELECT ok(
    EXISTS (SELECT 1 FROM regions_test WHERE id = 1),
    'Region should still exist after failed delete attempt'
);

-- =====================================================
-- TEST: Updating foreign key references
-- =====================================================

-- Switch to user2 for customer tests
select authenticate_as('user2');

-- Test updating a customer's region_id to another valid region
SELECT lives_ok(
    $$
    UPDATE customers_test SET region_id = 2 WHERE email = 'test@example.com'
    $$,
    'Should be able to update customer region_id to another valid region'
);

-- Verify the update
SELECT is(
    (SELECT region_id FROM customers_test WHERE email = 'test@example.com'),
    2,
    'Customer region_id should be updated to 2'
);

-- Test updating a customer's region_id to NULL
SELECT lives_ok(
    $$
    UPDATE customers_test SET region_id = NULL WHERE email = 'test@example.com'
    $$,
    'Should be able to update customer region_id to NULL'
);

-- =====================================================
-- TEST: Format 'reference' is properly mapped to INTEGER
-- =====================================================

-- Verify that the region_id column is INTEGER type
SELECT is(
    (SELECT data_type FROM information_schema.columns 
     WHERE table_name = 'customers_test' AND column_name = 'region_id'),
    'integer',
    'region_id column should have INTEGER data type'
);

-- Verify that the department_id column is INTEGER type
SELECT is(
    (SELECT data_type FROM information_schema.columns 
     WHERE table_name = 'employees_test' AND column_name = 'department_id'),
    'integer',
    'department_id column should have INTEGER data type'
);

SELECT * FROM finish();
ROLLBACK;
