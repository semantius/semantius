-- =====================================================
-- NORTHWIND RBAC TESTS (0040)
-- =====================================================
-- Access to the nwind data per identity:
--   user1 (1001, role User only)            -> sees nothing of Northwind
--   user2 (1002, User + northwind_sales)    -> reads and writes every entity
--   user3 (1003, User + Administrator)      -> sees everything
-- Also: audit_record_logs rows for user2 writes on products (audit_log=TRUE)
-- and none for categories, reference delete modes (clear on
-- employees.reports_to, restrict on seeded rows), the order-insert queue
-- mapping (message read as owner, filtered by the new order id) and the
-- orders.status enum. All writes roll back.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(32);

-- =====================================================
-- user1: no nwind:view
-- =====================================================
SELECT authenticate_as('user1');

-- Test 1: no customers
SELECT is(
    (SELECT COUNT(*)::integer FROM customers),
    0,
    'user1 should not see any customers (no nwind:view)'
);

-- Test 2: Northwind module invisible
SELECT is(
    (SELECT COUNT(*)::integer FROM modules WHERE module_slug = 'nwind'),
    0,
    'user1 should not see the Northwind module'
);

-- Test 3: Northwind absent from get_userinfo().modules
SELECT ok(
    NOT (public.get_userinfo()->'modules' @> '[{"module_slug": "nwind"}]'::jsonb),
    'user1 get_userinfo() modules should not include Northwind'
);

-- Test 4: module cube empty
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_module_cubes('nwind')),
    0,
    'user1 get_module_cubes(''nwind'') should return no schemas'
);

-- Test 5: no nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    false,
    'user1 should not have nwind:view'
);

-- Test 6: INSERT rejected by RLS
SELECT throws_ok(
    $$INSERT INTO categories (category_name) VALUES ('user1 category')$$,
    '42501',
    NULL,
    'user1 INSERT into categories should be rejected (42501)'
);

-- =====================================================
-- user2: Northwind Sales (nwind:view + nwind:manage)
-- =====================================================
SELECT authenticate_as('user2');

-- Test 7: all customers
SELECT is(
    (SELECT COUNT(*)::integer FROM customers),
    91,
    'user2 should see all 91 customers'
);

-- Test 8: nwind:view
SELECT is(
    rbac.has_permission('nwind:view'),
    true,
    'user2 should have nwind:view'
);

-- Test 9: nwind:manage
SELECT is(
    rbac.has_permission('nwind:manage'),
    true,
    'user2 should have nwind:manage'
);

-- Test 10: not an admin
SELECT is(
    rbac.has_permission('admin'),
    false,
    'user2 should not have admin'
);

-- Test 11: CRUD on categories - create
SELECT lives_ok(
    $$INSERT INTO categories (category_name, description) VALUES ('RBAC Category', 'created by user2')$$,
    'user2 should be able to INSERT a category'
);

-- Test 12: CRUD on categories - update + read back
UPDATE categories SET description = 'updated by user2' WHERE category_name = 'RBAC Category';
SELECT is(
    (SELECT description FROM categories WHERE category_name = 'RBAC Category'),
    'updated by user2',
    'user2 should be able to UPDATE and read back the category'
);

-- Test 13: CRUD on categories - delete
DELETE FROM categories WHERE category_name = 'RBAC Category';
SELECT is(
    (SELECT COUNT(*)::integer FROM categories WHERE category_name = 'RBAC Category'),
    0,
    'user2 should be able to DELETE the category'
);

-- Test 14: Northwind in get_userinfo().modules
SELECT ok(
    (public.get_userinfo()->'modules' @> '[{"module_name": "Northwind", "module_slug": "nwind"}]'::jsonb),
    'user2 get_userinfo() modules should include Northwind'
);

-- Test 15: modules visible = Northwind only (not _core)
SELECT set_eq(
    $$SELECT module_slug FROM modules$$,
    ARRAY['nwind'],
    'user2 should see exactly the Northwind module'
);

-- Test 16: webhook receivers are admin-only
SELECT is(
    (SELECT COUNT(*)::integer FROM webhook_receivers),
    0,
    'user2 should not see webhook_receivers (admin-only)'
);

-- =====================================================
-- user3: Administrator (formerly central 0140)
-- =====================================================
SELECT authenticate_as('user3');

-- Test 17: rbac.uid()
SELECT is(
    rbac.uid(),
    'user3',
    'rbac.uid() should return user3'
);

-- Test 18: user:read inherited via user:manage
SELECT is(
    rbac.has_permission('user:read'),
    true,
    'user3 (Administrator) should have user:read permission'
);

-- Test 19: admin
SELECT is(
    rbac.has_permission('admin'),
    true,
    'user3 (Administrator) should have admin permission'
);

-- Test 20: all customers
SELECT is(
    (SELECT COUNT(*)::integer FROM customers),
    91,
    'Administrator should be able to read all 91 customers'
);

-- Test 21: a known row
SELECT is(
    (SELECT company_name FROM customers WHERE customer_id = 'ALFKI'),
    'Alfreds Futterkiste',
    'Administrator should be able to read specific customer details (ALFKI)'
);

-- Test 22: sees _core and Northwind
SELECT set_eq(
    $$SELECT module_name FROM modules WHERE module_name IN ('_core', 'Northwind')$$,
    ARRAY['_core', 'Northwind'],
    'Administrator should see both the _core and Northwind modules'
);

-- =====================================================
-- AUDIT: user2 writes on products are logged with user_id 1002
-- =====================================================
SELECT authenticate_as('user2');

INSERT INTO products (product_name, supplier_id, category_id, unit_price)
VALUES ('RBAC Audit Product', 1, 1, 1.0);

UPDATE products SET unit_price = 2.5 WHERE product_name = 'RBAC Audit Product';

SELECT authenticate_as('user3');

-- Test 23: INSERT audited
SELECT is(
    (SELECT COUNT(*)::integer FROM audit_record_logs
     WHERE table_name = 'products' AND op = 'INSERT' AND user_id = 1002
       AND record_pk = (SELECT id FROM products WHERE product_name = 'RBAC Audit Product')::text),
    1,
    'user2 INSERT on products should be logged with user_id 1002'
);

-- Test 24: UPDATE audited
SELECT is(
    (SELECT COUNT(*)::integer FROM audit_record_logs
     WHERE table_name = 'products' AND op = 'UPDATE' AND user_id = 1002
       AND record_pk = (SELECT id FROM products WHERE product_name = 'RBAC Audit Product')::text
       AND (record->>'unit_price')::numeric = 2.5
       AND (old_record->>'unit_price')::numeric = 1.0),
    1,
    'user2 UPDATE on products should be logged with user_id 1002 and the new value'
);

-- Test 25: categories (audit_log=FALSE) produced no audit rows
SELECT is(
    (SELECT COUNT(*)::integer FROM audit_record_logs WHERE table_name = 'categories'),
    0,
    'categories writes should not be audited (audit_log=FALSE)'
);

-- =====================================================
-- REFERENCE DELETE MODES (as user2)
-- =====================================================
SELECT authenticate_as('user2');

-- clear: deleting a manager nulls reports_to on the report (fresh in-tx rows)
INSERT INTO employees (last_name, first_name) VALUES ('RBAC Manager', 'M');
INSERT INTO employees (last_name, first_name, reports_to)
VALUES ('RBAC Report', 'R', (SELECT id FROM employees WHERE last_name = 'RBAC Manager'));
DELETE FROM employees WHERE last_name = 'RBAC Manager';

-- Test 26
SELECT ok(
    (SELECT reports_to IS NULL FROM employees WHERE last_name = 'RBAC Report'),
    'Deleting a manager should clear reports_to on the report (ON DELETE SET NULL)'
);

-- Test 27: restrict - seeded employee 1 is referenced by orders.
-- ON DELETE RESTRICT raises 23001 (restrict_violation) on PostgreSQL 18, but
-- 23503 (foreign_key_violation) on PG<=17 (Neon/Supabase). Match the FK-violation
-- message common to both codes so the test is valid on either version
-- (same approach as apps/test/tests/0160_test_foreign_keys.sql).
SELECT throws_like(
    $$DELETE FROM employees WHERE id = 1$$,
    '%foreign key constraint%',
    'Deleting seeded employee 1 should be blocked by orders.employee_id (restrict)'
);

-- =====================================================
-- QUEUE: an order INSERT enqueues an entity_event on "events"
-- =====================================================
INSERT INTO orders (ship_name, customer_id)
VALUES ('RBAC Queue Order', (SELECT id FROM customers WHERE customer_id = 'ALFKI'));

-- pgmq is owner-only; filter by our own id (the queue may hold other messages)
RESET ROLE;

-- Test 28
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgmq.read('events', 0, 1000)
        WHERE message->>'table' = 'orders'
          AND message->>'event_type' = 'insert'
          AND message->>'id_field' = 'id'
          AND (message->'id_value')::bigint = (SELECT id FROM orders WHERE ship_name = 'RBAC Queue Order')
    ),
    'Inserting an order should enqueue an insert event for that order id on the events queue'
);

-- Test 29
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgmq.read('events', 0, 1000)
        WHERE (message->'id_value')::bigint = (SELECT id FROM orders WHERE ship_name = 'RBAC Queue Order')
          AND message->>'message_type' = 'entity_event'
          AND message->>'op' = 'INSERT'
    ),
    'The queued order message should be an entity_event with op INSERT'
);

-- =====================================================
-- ORDER STATUS ENUM (as user2)
-- =====================================================
SELECT authenticate_as('user2');

-- Test 30: invalid value
SELECT throws_ok(
    $$INSERT INTO orders (ship_name, customer_id, status)
      VALUES ('RBAC Bogus Status', (SELECT id FROM customers WHERE customer_id = 'ALFKI'), 'bogus')$$,
    '23514',
    NULL,
    'orders.status = bogus should be rejected (23514)'
);

-- Test 31: empty string rejected (required enum)
SELECT throws_ok(
    $$INSERT INTO orders (ship_name, customer_id, status)
      VALUES ('RBAC Empty Status', (SELECT id FROM customers WHERE customer_id = 'ALFKI'), '')$$,
    '23514',
    NULL,
    'orders.status = '''' should be rejected (required enum, 23514)'
);

-- Test 32: omitted status defaults to pending
INSERT INTO orders (ship_name, customer_id)
VALUES ('RBAC Default Status', (SELECT id FROM customers WHERE customer_id = 'ALFKI'));

SELECT is(
    (SELECT status FROM orders WHERE ship_name = 'RBAC Default Status'),
    'pending',
    'orders.status should default to pending when omitted'
);

SELECT * FROM finish();
ROLLBACK;
