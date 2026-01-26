-- Test foreign key functionality
BEGIN;

SELECT plan(26);

-- =====================================================
-- TEST: Foreign key constraints are created
-- =====================================================
select authenticate_as('user1');

-- Test that customers.region_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'customers_region_id_fkey'
        AND conrelid = 'customers'::regclass
    ),
    'Foreign key constraint customers_region_id_fkey should exist'
);

-- Test that employees.department_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'employees_department_id_fkey'
        AND conrelid = 'employees'::regclass
    ),
    'Foreign key constraint employees_department_id_fkey should exist'
);

-- Test that indexes are created for foreign key columns
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'customers'
        AND indexname = 'idx_customers_region_id'
    ),
    'Index idx_customers_region_id should exist'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'employees'
        AND indexname = 'idx_employees_department_id'
    ),
    'Index idx_employees_department_id should exist'
);

-- =====================================================
-- TEST: Valid references can be inserted
-- =====================================================

-- Switch to admin to insert test data
select authenticate_as('user3');

-- Test inserting a customer with a valid region_id
SELECT lives_ok(
    $$
    INSERT INTO customers (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('Test Customer', 'test@example.com', '+1-555-0199', 'Test Corp', 'active', 0, 1)
    $$,
    'Should be able to insert customer with valid region_id'
);

-- Test inserting an employee with a valid department_id
SELECT lives_ok(
    $$
    INSERT INTO employees (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('Test Employee', 'test.employee@company.com', 1, 'Test Position', '2023-01-01', 50000, TRUE)
    $$,
    'Should be able to insert employee with valid department_id'
);

-- =====================================================
-- TEST: Invalid references are rejected
-- =====================================================

-- Test that inserting a customer with invalid region_id fails
SELECT throws_ok(
    $$
    INSERT INTO customers (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('Invalid Customer', 'invalid@example.com', '+1-555-0198', 'Invalid Corp', 'active', 0, 9999)
    $$,
    '23503',
    NULL,
    'Should not be able to insert customer with invalid region_id'
);

-- Test that inserting an employee with invalid department_id fails
SELECT throws_ok(
    $$
    INSERT INTO employees (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('Invalid Employee', 'invalid.employee@company.com', 9999, 'Invalid Position', '2023-01-01', 50000, TRUE)
    $$,
    '23503',
    NULL,
    'Should not be able to insert employee with invalid department_id'
);

-- =====================================================
-- TEST: NULL values are allowed for nullable foreign keys
-- =====================================================

-- Test inserting a customer with NULL region_id (region_id is nullable)
SELECT lives_ok(
    $$
    INSERT INTO customers (customer_name, email, phone, company, status, total_orders, region_id)
    VALUES ('No Region Customer', 'noregion@example.com', '+1-555-0197', 'No Region Corp', 'active', 0, NULL)
    $$,
    'Should be able to insert customer with NULL region_id (nullable)'
);

-- =====================================================
-- TEST: NULL values are rejected for non-nullable foreign keys
-- =====================================================

-- Test that inserting an employee with NULL department_id fails (department_id is NOT NULL)
SELECT throws_ok(
    $$
    INSERT INTO employees (full_name, email, department_id, position, hire_date, salary, is_active)
    VALUES ('No Dept Employee', 'nodept.employee@company.com', NULL, 'No Dept Position', '2023-01-01', 50000, TRUE)
    $$,
    '23502',
    NULL,
    'Should not be able to insert employee with NULL department_id (NOT NULL)'
);

-- =====================================================
-- TEST: ON DELETE RESTRICT behavior for employees-departments
-- =====================================================

-- Try to delete a department that has employees (should fail due to RESTRICT)
SELECT throws_ok(
    $$
    DELETE FROM departments WHERE id = 1
    $$,
    '23503',
    NULL,
    'Should not be able to delete department with existing employees (RESTRICT)'
);

-- Verify the department still exists
SELECT ok(
    EXISTS (SELECT 1 FROM departments WHERE id = 1),
    'Department should still exist after failed delete attempt'
);

-- Delete the test employee first, then delete should succeed
DELETE FROM employees WHERE email = 'test.employee@company.com';

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
    'Should be able to delete department without employees'
);

-- =====================================================
-- TEST: ON DELETE RESTRICT behavior for customers-regions (default)
-- =====================================================

-- Try to delete a region that has customers (should fail due to RESTRICT)
SELECT throws_ok(
    $$
    DELETE FROM regions WHERE id = 1
    $$,
    '23503',
    NULL,
    'Should not be able to delete region with existing customers (RESTRICT)'
);

-- Verify the region still exists
SELECT ok(
    EXISTS (SELECT 1 FROM regions WHERE id = 1),
    'Region should still exist after failed delete attempt'
);

-- =====================================================
-- TEST: Updating foreign key references
-- =====================================================

-- Test updating a customer's region_id to another valid region
SELECT lives_ok(
    $$
    UPDATE customers SET region_id = 2 WHERE email = 'test@example.com'
    $$,
    'Should be able to update customer region_id to another valid region'
);

-- Verify the update
SELECT is(
    (SELECT region_id FROM customers WHERE email = 'test@example.com'),
    2,
    'Customer region_id should be updated to 2'
);

-- Test updating a customer's region_id to NULL
SELECT lives_ok(
    $$
    UPDATE customers SET region_id = NULL WHERE email = 'test@example.com'
    $$,
    'Should be able to update customer region_id to NULL'
);

-- =====================================================
-- TEST: Test ON DELETE SET NULL behavior (clear mode)
-- =====================================================

-- Create a test table and field with reference_delete_mode = 'clear'
INSERT INTO tables (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'test_table_clear',
    'test_item',
    'Test Item',
    'Test Items',
    'Test table for ON DELETE SET NULL behavior',
    1001,
    'public:read',
    'admin',
    'id',
    'item_name'
);

-- Add a reference field with clear mode (SET NULL)
INSERT INTO fields (table_name, field_name, title, format, is_pk, is_nullable, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable)
VALUES 
    ('test_table_clear', 'region_id', 'Region', 'reference', FALSE, TRUE, 10, 'default', 's', 'Region for this item', 'regions', 'clear', FALSE);

-- Insert a test record
INSERT INTO test_table_clear (item_name, region_id)
VALUES ('Test Item 1', 3);

-- Verify the record was inserted with region_id = 3
SELECT is(
    (SELECT region_id FROM test_table_clear WHERE item_name = 'Test Item 1'),
    3,
    'Test item should have region_id = 3'
);

-- Delete the region (should SET NULL due to clear mode)
DELETE FROM regions WHERE id = 3;

-- Verify the region_id was set to NULL
SELECT is(
    (SELECT region_id FROM test_table_clear WHERE item_name = 'Test Item 1'),
    NULL,
    'Test item region_id should be NULL after region deletion (SET NULL)'
);

-- Cleanup
DELETE FROM test_table_clear WHERE item_name = 'Test Item 1';
DELETE FROM tables WHERE table_name = 'test_table_clear';

-- =====================================================
-- TEST: Format 'reference' is properly mapped to INTEGER
-- =====================================================

-- Verify that the region_id column is INTEGER type
SELECT is(
    (SELECT data_type FROM information_schema.columns 
     WHERE table_name = 'customers' AND column_name = 'region_id'),
    'integer',
    'region_id column should have INTEGER data type'
);

-- Verify that the department_id column is INTEGER type
SELECT is(
    (SELECT data_type FROM information_schema.columns 
     WHERE table_name = 'employees' AND column_name = 'department_id'),
    'integer',
    'department_id column should have INTEGER data type'
);

SELECT * FROM finish();
ROLLBACK;
