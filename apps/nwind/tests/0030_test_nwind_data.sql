-- =====================================================
-- NORTHWIND DATA TESTS (0030)
-- =====================================================
-- Integrity of the loaded Northwind dataset: row counts, known rows
-- (ALFKI / VINET / order 10248), the reports_to tree, order status vs
-- shipped_date, sequences caught up after the load, categories.sort_order
-- auto-assignment, composed labels, non-ASCII data, and the CURRENT_DATE
-- defaults on hire_date / order_date. Sequences are inspected as the owner
-- (before authenticate_as); everything else is read as user2 (Northwind
-- Sales), i.e. through nwind:view RLS. All writes roll back.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(36);

-- =====================================================
-- SEQUENCES (owner): caught up with the explicit ids of the load
-- =====================================================
-- nextval() is never rolled back, so concurrent/previous test inserts may have
-- advanced the sequences beyond MAX(id); the invariant is ">=" (no collisions).

-- Test 1: every id sequence is at or beyond the highest loaded id
SELECT ok(
    pg_sequence_last_value('categories_id_seq') >= (SELECT MAX(id) FROM categories)
    AND pg_sequence_last_value('suppliers_id_seq') >= (SELECT MAX(id) FROM suppliers)
    AND pg_sequence_last_value('employees_id_seq') >= (SELECT MAX(id) FROM employees)
    AND pg_sequence_last_value('products_id_seq')  >= (SELECT MAX(id) FROM products)
    AND pg_sequence_last_value('regions_id_seq')   >= (SELECT MAX(id) FROM regions)
    AND pg_sequence_last_value('shippers_id_seq')  >= (SELECT MAX(id) FROM shippers)
    AND pg_sequence_last_value('orders_id_seq')    >= (SELECT MAX(id) FROM orders),
    'All nwind id sequences should be caught up with the loaded data (>= MAX(id))'
);

-- Test 2: the highest loaded order id is 11077
SELECT is(
    (SELECT MAX(id) FROM orders),
    11077,
    'Highest loaded order id should be 11077'
);

SELECT authenticate_as('user2');

-- =====================================================
-- ROW COUNTS (full Northwind dataset)
-- =====================================================

-- Test 3
SELECT is((SELECT COUNT(*)::integer FROM categories), 8, 'categories should have 8 rows');
-- Test 4
SELECT is((SELECT COUNT(*)::integer FROM regions), 4, 'regions should have 4 rows');
-- Test 5
SELECT is((SELECT COUNT(*)::integer FROM territories), 53, 'territories should have 53 rows');
-- Test 6
SELECT is((SELECT COUNT(*)::integer FROM employees), 9, 'employees should have 9 rows');
-- Test 7
SELECT is((SELECT COUNT(*)::integer FROM shippers), 6, 'shippers should have 6 rows');
-- Test 8
SELECT is((SELECT COUNT(*)::integer FROM suppliers), 29, 'suppliers should have 29 rows');
-- Test 9
SELECT is((SELECT COUNT(*)::integer FROM products), 77, 'products should have 77 rows');
-- Test 10
SELECT is((SELECT COUNT(*)::integer FROM customers), 91, 'customers should have 91 rows');
-- Test 11
SELECT is((SELECT COUNT(*)::integer FROM orders), 830, 'orders should have 830 rows');
-- Test 12
SELECT is((SELECT COUNT(*)::integer FROM order_details), 2155, 'order_details should have 2155 rows');
-- Test 13
SELECT is((SELECT COUNT(*)::integer FROM employee_territories), 49, 'employee_territories should have 49 rows');

-- =====================================================
-- KNOWN ROWS
-- =====================================================

-- Test 14: customers contain ALFKI, ANATR and VINET
SELECT is(
    (SELECT COUNT(*)::integer FROM customers WHERE customer_id IN ('ALFKI', 'ANATR', 'VINET')),
    3,
    'customers should contain ALFKI, ANATR, and VINET customer codes'
);

-- Test 15: customers.customer_id stores the original text code
SELECT is(
    (SELECT customer_id FROM customers WHERE company_name = 'Alfreds Futterkiste'),
    'ALFKI',
    'customers should store original ALFKI text code in customer_id field'
);

-- Test 16: categories contain Beverages, Condiments and Confections
SELECT is(
    (SELECT COUNT(*)::integer FROM categories WHERE category_name IN ('Beverages', 'Condiments', 'Confections')),
    3,
    'categories should contain Beverages, Condiments, and Confections'
);

-- Test 17: orders.customer_id integer FK joins to customers.id
SELECT is(
    (SELECT c.company_name
     FROM orders o
     JOIN customers c ON c.id = o.customer_id
     WHERE o.id = 10248),
    'Vins et alcools Chevalier',
    'orders.customer_id integer FK should join correctly to customers.id'
);

-- Test 18: order 10248 has 3 lines
SELECT is(
    (SELECT COUNT(*)::integer
     FROM order_details od
     JOIN orders o ON o.id = od.order_id
     JOIN products p ON p.id = od.product_id
     WHERE o.id = 10248),
    3,
    'Order 10248 should have 3 order detail lines'
);

-- Test 19: Davolio has exactly the Wilton and Neward territories
SELECT set_eq(
    $$SELECT t.territory_description
      FROM employee_territories et
      JOIN employees e ON e.id = et.employee_id
      JOIN territories t ON t.id = et.territory_id
      WHERE e.last_name = 'Davolio'$$,
    ARRAY['Wilton', 'Neward'],
    'Employee Davolio should be assigned exactly the Wilton and Neward territories'
);

-- =====================================================
-- REPORTS_TO TREE
-- =====================================================

-- Test 20: Fuller manages 1, 3, 4, 5, 8
SELECT set_eq(
    $$SELECT id FROM employees
      WHERE reports_to = (SELECT id FROM employees WHERE last_name = 'Fuller')$$,
    ARRAY[1, 3, 4, 5, 8],
    'Fuller should manage employees 1, 3, 4, 5 and 8'
);

-- Test 21: Buchanan manages 6, 7, 9
SELECT set_eq(
    $$SELECT id FROM employees
      WHERE reports_to = (SELECT id FROM employees WHERE last_name = 'Buchanan')$$,
    ARRAY[6, 7, 9],
    'Buchanan should manage employees 6, 7 and 9'
);

-- Test 22: Fuller is the root (reports_to NULL)
SELECT ok(
    (SELECT reports_to IS NULL FROM employees WHERE last_name = 'Fuller'),
    'Fuller (Vice President) should have reports_to = NULL'
);

-- Test 23: courtesy titles used in the data
SELECT set_eq(
    $$SELECT DISTINCT title_of_courtesy FROM employees$$,
    ARRAY['Dr.', 'Mr.', 'Mrs.', 'Ms.'],
    'employees.title_of_courtesy should use exactly Dr., Mr., Mrs., Ms.'
);

-- Test 24: supplier 2 keeps its raw homepage value through the url format
SELECT is(
    (SELECT homepage FROM suppliers WHERE id = 2),
    '#CAJUN.HTM#',
    'Supplier 2 homepage should be loaded verbatim (#CAJUN.HTM#)'
);

-- =====================================================
-- ORDER STATUS
-- =====================================================

-- Test 25: 21 pending orders
SELECT is(
    (SELECT COUNT(*)::integer FROM orders WHERE status = 'pending'),
    21,
    'There should be 21 pending orders'
);

-- Test 26: 809 shipped orders
SELECT is(
    (SELECT COUNT(*)::integer FROM orders WHERE status = 'shipped'),
    809,
    'There should be 809 shipped orders'
);

-- Test 27: pending <=> shipped_date IS NULL
SELECT is(
    (SELECT COUNT(*)::integer FROM orders WHERE (status = 'pending') <> (shipped_date IS NULL)),
    0,
    'status = pending should hold exactly for orders without a shipped_date'
);

-- =====================================================
-- ORDER COLUMN
-- =====================================================

-- Test 28: categories.sort_order was auto-assigned 10, 20, ... in id order
SELECT ok(
    (SELECT bool_and(sort_order = 10 * id) FROM categories),
    'categories.sort_order should be 10 * id (auto-assigned in load order)'
);

-- =====================================================
-- COMPOSED LABELS
-- =====================================================

-- Test 29: territory label folds the region in
SELECT is(
    (SELECT public._label(t) FROM territories t WHERE t.territory_id = '01581'),
    'Eastern › Westboro',
    'territories._label should compose region › territory'
);

-- Test 30: junction label folds both legs
SELECT is(
    (SELECT public._label(et)
     FROM employee_territories et
     JOIN employees e ON e.id = et.employee_id
     JOIN territories t ON t.id = et.territory_id
     WHERE e.last_name = 'Davolio' AND t.territory_description = 'Wilton'),
    'Davolio › Eastern › Wilton',
    'employee_territories._label should compose employee › region › territory'
);

-- Test 31: order line label is its order (empty local label)
SELECT is(
    (SELECT DISTINCT public._label(od) FROM order_details od WHERE od.order_id = 10248),
    'Vins et alcools Chevalier',
    'order_details._label should be the parent order label'
);

-- =====================================================
-- NON-ASCII DATA
-- =====================================================

-- Test 32: umlaut in order ship_name
SELECT is(
    (SELECT ship_name FROM orders WHERE id = 10249),
    'Toms Spezialitäten',
    'Order 10249 ship_name should keep its non-ASCII characters'
);

-- Test 33: umlauts in supplier name
SELECT is(
    (SELECT COUNT(*)::integer FROM suppliers WHERE company_name = 'PB Knäckebröd AB'),
    1,
    'Supplier "PB Knäckebröd AB" should be loaded with its non-ASCII characters'
);

-- =====================================================
-- DATE DEFAULTS (CURRENT_DATE), written as user2
-- =====================================================

INSERT INTO orders (ship_name, customer_id)
VALUES ('Date Default Order', (SELECT id FROM customers WHERE customer_id = 'ALFKI'));

-- Test 34: order_date defaults to CURRENT_DATE
SELECT is(
    (SELECT order_date FROM orders WHERE ship_name = 'Date Default Order'),
    CURRENT_DATE,
    'orders.order_date should default to CURRENT_DATE'
);

-- Test 35: required_date defaults to CURRENT_DATE
SELECT is(
    (SELECT required_date FROM orders WHERE ship_name = 'Date Default Order'),
    CURRENT_DATE,
    'orders.required_date should default to CURRENT_DATE'
);

INSERT INTO employees (last_name, first_name) VALUES ('Date Default', 'Employee');

-- Test 36: hire_date defaults to CURRENT_DATE
SELECT is(
    (SELECT hire_date FROM employees WHERE last_name = 'Date Default'),
    CURRENT_DATE,
    'employees.hire_date should default to CURRENT_DATE'
);

SELECT * FROM finish();
ROLLBACK;
