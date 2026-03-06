-- =====================================================
-- NORTHWIND MODULE TESTS
-- =====================================================
-- Tests for the nwind module setup: module, permissions,
-- entity tables, fields, and sample data integrity.
-- Requires apps/test/migrations/0035_seed_nwind.sql
-- =====================================================

BEGIN;

SELECT plan(35);

-- =====================================================
-- MODULE TESTS
-- =====================================================

-- Test 1: nwind module exists
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_name = 'nwind'),
    1,
    'nwind module should exist'
);

-- Test 2: nwind module has correct view_permission
SELECT is(
    (SELECT view_permission FROM modules WHERE module_name = 'nwind'),
    'nwind:view',
    'nwind module should have view_permission = nwind:view'
);

-- =====================================================
-- PERMISSION TESTS
-- =====================================================

-- Test 3: nwind:view permission exists
SELECT is(
    (SELECT COUNT(*)::integer FROM permissions WHERE permission_name = 'nwind:view'),
    1,
    'nwind:view permission should exist'
);

-- Test 4: nwind:manage permission exists
SELECT is(
    (SELECT COUNT(*)::integer FROM permissions WHERE permission_name = 'nwind:manage'),
    1,
    'nwind:manage permission should exist'
);

-- Test 5: nwind:manage implies nwind:view via permission hierarchy
SELECT is(
    (SELECT COUNT(*)::integer
     FROM permission_hierarchy ph
     JOIN permissions p ON p.id = ph.parent_permission_id
     JOIN permissions c ON c.id = ph.child_permission_id
     WHERE p.permission_name = 'nwind:manage'
       AND c.permission_name = 'nwind:view'),
    1,
    'nwind:manage should imply nwind:view in permission hierarchy'
);

-- =====================================================
-- ENTITY TABLE EXISTENCE TESTS
-- =====================================================

-- Test 6: categories table exists
SELECT has_table('public', 'categories', 'categories table should exist');

-- Test 7: suppliers table exists
SELECT has_table('public', 'suppliers', 'suppliers table should exist');

-- Test 8: customer_demographics table exists
SELECT has_table('public', 'customer_demographics', 'customer_demographics table should exist');

-- Test 9: customers table exists
SELECT has_table('public', 'customers', 'customers table should exist');

-- Test 10: regions table exists
SELECT has_table('public', 'regions', 'regions table should exist');

-- Test 11: shippers table exists
SELECT has_table('public', 'shippers', 'shippers table should exist');

-- Test 12: employees table exists
SELECT has_table('public', 'employees', 'employees table should exist');

-- Test 13: products table exists
SELECT has_table('public', 'products', 'products table should exist');

-- Test 14: territories table exists
SELECT has_table('public', 'territories', 'territories table should exist');

-- Test 15: orders table exists
SELECT has_table('public', 'orders', 'orders table should exist');

-- Test 16: customer_customer_demo table exists
SELECT has_table('public', 'customer_customer_demo', 'customer_customer_demo table should exist');

-- Test 17: employee_territories table exists
SELECT has_table('public', 'employee_territories', 'employee_territories table should exist');

-- Test 18: order_details table exists
SELECT has_table('public', 'order_details', 'order_details table should exist');

-- Test 19: us_states table exists
SELECT has_table('public', 'us_states', 'us_states table should exist');

-- =====================================================
-- UNIQUE FIELD TESTS (non-integer original PKs)
-- =====================================================

-- Test 20: customers.customer_id has a unique index
SELECT is(
    (SELECT COUNT(*)::integer
     FROM pg_indexes
     WHERE tablename = 'customers'
       AND indexname = 'customers_customer_id_unique'),
    1,
    'Unique index customers_customer_id_unique should exist for text customer codes'
);

-- Test 21: territories.territory_id has a unique index
SELECT is(
    (SELECT COUNT(*)::integer
     FROM pg_indexes
     WHERE tablename = 'territories'
       AND indexname = 'territories_territory_id_unique'),
    1,
    'Unique index territories_territory_id_unique should exist for text territory codes'
);

-- =====================================================
-- FIELD DEFINITION TESTS
-- =====================================================

-- Test 22: categories has correct field count (id + label + created_at + updated_at auto-created + description)
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'categories'),
    5,
    'categories should have 5 fields (id, category_name, created_at, updated_at auto-created + description)'
);

-- Test 23: customers has unique_value=TRUE on customer_id
SELECT is(
    (SELECT unique_value FROM fields WHERE table_name = 'customers' AND field_name = 'customer_id'),
    TRUE,
    'customers.customer_id field should have unique_value=TRUE'
);

-- Test 24: territories has unique_value=TRUE on territory_id
SELECT is(
    (SELECT unique_value FROM fields WHERE table_name = 'territories' AND field_name = 'territory_id'),
    TRUE,
    'territories.territory_id field should have unique_value=TRUE'
);

-- Test 25: products has reference field for category_id pointing to categories
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'products' AND field_name = 'category_id'),
    'categories',
    'products.category_id should reference categories table'
);

-- Test 26: orders has reference field for customer_id pointing to customers
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'orders' AND field_name = 'customer_id'),
    'customers',
    'orders.customer_id should reference customers table'
);

-- Test 27: employee_territories is a child entity (is_child=TRUE from parent fields)
SELECT is(
    (SELECT is_child FROM entities WHERE table_name = 'employee_territories'),
    TRUE,
    'employee_territories should be a child entity (has parent format fields)'
);

-- Test 28: order_details is a child entity
SELECT is(
    (SELECT is_child FROM entities WHERE table_name = 'order_details'),
    TRUE,
    'order_details should be a child entity (has parent format fields)'
);

-- =====================================================
-- DATA INTEGRITY TESTS
-- =====================================================

-- Test 29: categories has data
SELECT is(
    (SELECT COUNT(*)::integer FROM categories),
    3,
    'categories should have 3 rows of test data'
);

-- Test 30: regions has 4 rows
SELECT is(
    (SELECT COUNT(*)::integer FROM regions),
    4,
    'regions should have 4 rows (Eastern, Western, Northern, Southern)'
);

-- Test 31: customers has 3 rows
SELECT is(
    (SELECT COUNT(*)::integer FROM customers),
    3,
    'customers should have 3 rows of test data'
);

-- Test 32: customers.customer_id stores original text codes
SELECT is(
    (SELECT customer_id FROM customers WHERE company_name = 'Alfreds Futterkiste'),
    'ALFKI',
    'customers should store original ALFKI text code in customer_id field'
);

-- Test 33: orders FK resolves to integer id (not text code)
SELECT is(
    (SELECT c.company_name
     FROM orders o
     JOIN customers c ON c.id = o.customer_id
     WHERE o.id = 10248),
    'Alfreds Futterkiste',
    'orders.customer_id integer FK should join correctly to customers.id'
);

-- Test 34: employee_territories correctly links employees and territories
SELECT is(
    (SELECT COUNT(*)::integer
     FROM employee_territories et
     JOIN employees e ON e.id = et.employee_id
     JOIN territories t ON t.id = et.territory_id
     WHERE e.last_name = 'Davolio'),
    2,
    'Employee Davolio should have 2 territory assignments'
);

-- Test 35: order_details correctly references orders and products
SELECT is(
    (SELECT COUNT(*)::integer
     FROM order_details od
     JOIN orders o ON o.id = od.order_id
     JOIN products p ON p.id = od.product_id
     WHERE o.id = 10248),
    2,
    'Order 10248 should have 2 order detail lines'
);

SELECT * FROM finish();
ROLLBACK;
