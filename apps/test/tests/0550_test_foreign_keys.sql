-- Test foreign key functionality
--
-- Targets the persisted nwind sample module:
--   • products.supplier_id  → suppliers  (reference, restrict)
--   • products.category_id  → categories (reference, restrict)
--   • orders.customer_id    → customers  (reference, restrict, input_type='required')
--   • employees.reports_to  → employees  (reference, clear → ON DELETE SET NULL)
-- Every seeded category/supplier/customer/employee is referenced, so the
-- delete-mode scenarios insert fresh rows inside this transaction.
-- Writer is user2 (role Northwind Sales: nwind:view + nwind:manage). The last
-- part compares the hand-written foreign keys of the core tables, as user3.
BEGIN;

SELECT plan(23);

-- =====================================================
-- TEST: Foreign key constraints are created
-- =====================================================
select authenticate_as('user2');

-- Test 1: products.supplier_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'products_supplier_id_fkey'
        AND conrelid = 'products'::regclass
    ),
    'Foreign key constraint products_supplier_id_fkey should exist'
);

-- Test 2: orders.customer_id foreign key constraint exists
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'orders_customer_id_fkey'
        AND conrelid = 'orders'::regclass
    ),
    'Foreign key constraint orders_customer_id_fkey should exist'
);

-- Test 3/4: indexes are created for foreign key columns
SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'products'
        AND indexname = 'idx_products_supplier_id'
    ),
    'Index idx_products_supplier_id should exist'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'orders'
        AND indexname = 'idx_orders_customer_id'
    ),
    'Index idx_orders_customer_id should exist'
);

-- =====================================================
-- TEST: Valid references can be inserted
-- =====================================================

-- Test 5: product with a valid category_id and supplier_id
SELECT lives_ok(
    $$
    INSERT INTO products (product_name, category_id, supplier_id, unit_price, units_in_stock)
    VALUES ('FK Probe Product', 1, 1, 9.99, 5)
    $$,
    'Should be able to insert product with valid category_id and supplier_id'
);

-- Test 6: order with a valid customer_id (ALFKI)
SELECT lives_ok(
    $$
    INSERT INTO orders (ship_name, customer_id)
    VALUES ('FK Probe Order ALFKI', (SELECT id FROM customers WHERE customer_id = 'ALFKI'))
    $$,
    'Should be able to insert order with valid customer_id'
);

-- =====================================================
-- TEST: Invalid references are rejected
-- =====================================================

-- Test 7: product with an invalid category_id
SELECT throws_ok(
    $$
    INSERT INTO products (product_name, category_id, supplier_id)
    VALUES ('FK Invalid Product', 9999, 1)
    $$,
    '23503',
    NULL,
    'Should not be able to insert product with invalid category_id'
);

-- Test 8: order with an invalid customer_id
SELECT throws_ok(
    $$
    INSERT INTO orders (ship_name, customer_id)
    VALUES ('FK Invalid Order', 9999)
    $$,
    '23503',
    NULL,
    'Should not be able to insert order with invalid customer_id'
);

-- =====================================================
-- TEST: NULL values are allowed for reference fields (all references are nullable)
-- =====================================================

-- Test 9: product with NULL supplier_id
SELECT lives_ok(
    $$
    INSERT INTO products (product_name, category_id, supplier_id)
    VALUES ('FK No Supplier Product', 1, NULL)
    $$,
    'Should be able to insert product with NULL supplier_id (reference fields are nullable)'
);

-- Test 10: orders.customer_id has input_type='required'. The physical column stays
-- nullable, and the field's required check refuses the NULL.
SELECT throws_ok(
    $$
    INSERT INTO orders (ship_name, customer_id)
    VALUES ('FK No Customer Order', NULL)
    $$,
    '90258',
    NULL,
    'A required reference refuses NULL even though the column is nullable'
);

-- =====================================================
-- TEST: ON DELETE RESTRICT behavior for products-categories
-- =====================================================

-- Test 11: deleting a category that has products must fail (RESTRICT).
-- ON DELETE RESTRICT raises 23001 (restrict_violation) on PostgreSQL 18, but
-- 23503 (foreign_key_violation) on PG<=17 (Neon/Supabase). Match the FK-violation
-- message common to both codes so the test is valid on either version.
SELECT throws_like(
    $$
    DELETE FROM categories WHERE id = 1
    $$,
    '%foreign key constraint%',
    'Should not be able to delete category with existing products (RESTRICT)'
);

-- Test 12: the category still exists
SELECT ok(
    EXISTS (SELECT 1 FROM categories WHERE id = 1),
    'Category should still exist after failed delete attempt'
);

-- Test 13/14: a fresh, unreferenced category can be inserted and deleted
SELECT lives_ok(
    $$
    INSERT INTO categories (category_name, description)
    VALUES ('FK Probe Category', 'Category for FK delete test')
    $$,
    'Should be able to insert test category'
);

SELECT lives_ok(
    $$
    DELETE FROM categories WHERE category_name = 'FK Probe Category'
    $$,
    'Should be able to delete category without products'
);

-- =====================================================
-- TEST: Updating foreign key references
-- =====================================================

-- Test 15: move the probe product to another valid category
SELECT lives_ok(
    $$
    UPDATE products SET category_id = 2 WHERE product_name = 'FK Probe Product'
    $$,
    'Should be able to update product category_id to another valid category'
);

-- Test 16: verify the update
SELECT is(
    (SELECT category_id FROM products WHERE product_name = 'FK Probe Product'),
    2::bigint,
    'Product category_id should be updated to 2'
);

-- Test 17: clear the reference
SELECT lives_ok(
    $$
    UPDATE products SET category_id = NULL WHERE product_name = 'FK Probe Product'
    $$,
    'Should be able to update product category_id to NULL'
);

-- =====================================================
-- TEST: Format 'reference' is properly mapped to the referenced key's BIGINT
-- =====================================================

-- Test 18/19
SELECT is(
    (SELECT data_type FROM information_schema.columns
     WHERE table_name = 'products' AND column_name = 'category_id'),
    'bigint',
    'products.category_id column should have BIGINT data type (the type of categories.id)'
);

SELECT is(
    (SELECT data_type FROM information_schema.columns
     WHERE table_name = 'orders' AND column_name = 'customer_id'),
    'bigint',
    'orders.customer_id column should have BIGINT data type (the type of customers.id)'
);

-- =====================================================
-- TEST: reference_delete_mode='clear' (employees.reports_to → ON DELETE SET NULL)
-- A fresh manager has no orders/territories, so RESTRICT does not apply to it.
-- =====================================================

INSERT INTO employees (last_name, first_name, title)
VALUES ('FK Probe Manager', 'Max', 'Probe Manager');

INSERT INTO employees (last_name, first_name, title, reports_to)
VALUES ('FK Probe Report', 'Rhea', 'Probe Report',
        (SELECT id FROM employees WHERE last_name = 'FK Probe Manager'));

-- Test 20: precondition — the report points at the manager
SELECT is(
    (SELECT reports_to FROM employees WHERE last_name = 'FK Probe Report'),
    (SELECT id FROM employees WHERE last_name = 'FK Probe Manager'),
    'Report employee should reference the manager before the delete'
);

-- Test 21: deleting the manager succeeds (clear, not restrict)
SELECT lives_ok(
    $$
    DELETE FROM employees WHERE last_name = 'FK Probe Manager'
    $$,
    'Should be able to delete a manager that is referenced via reports_to (delete mode clear)'
);

-- Test 22: the report survives with reports_to cleared
SELECT is(
    (SELECT reports_to FROM employees WHERE last_name = 'FK Probe Report'),
    NULL::bigint,
    'reports_to should be set to NULL after the manager is deleted (delete mode clear)'
);

-- =====================================================
-- TEST: the core foreign keys written by hand have the generated form
-- =====================================================
-- 0060_rbac_schema.once.sql writes the foreign keys of the core tables with
-- the tables, and their fields rows in 0150_dd_bootstrap.once.sql say what
-- get_schema shows. For these seven the two agree in the form the dictionary
-- itself generates. A probe entity gets one field per core column, with that
-- column's reference_table and reference_delete_mode, and the constraint the
-- dictionary builds for it must read as the core one does, past the column.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

CREATE TEMP TABLE fk_core_columns (table_name TEXT, field_name TEXT);
INSERT INTO fk_core_columns VALUES
    ('modules', 'default_viewer_role_id'), ('modules', 'default_manager_role_id'),
    ('modules', 'default_admin_role_id'), ('user_roles', 'assigned_by'),
    ('role_permissions', 'granted_by'), ('user_permissions', 'granted_by'),
    ('roles', 'module_id');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('fk_form_probe', 'FK Form Probe', 'FK Form Probes', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
SELECT 'fk_form_probe', c.table_name || '__' || c.field_name, c.table_name || ' ' || c.field_name, 'reference',
       100 + row_number() OVER (ORDER BY c.table_name, c.field_name), f.reference_table, f.reference_delete_mode
  FROM fk_core_columns c
  JOIN fields f ON f.table_name = c.table_name AND f.field_name = c.field_name;

-- The definition of the foreign key on one column, without the column.
CREATE FUNCTION pg_temp.fk_form(p_table TEXT, p_column TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT regexp_replace(pg_get_constraintdef(c.oid), '^FOREIGN KEY \([^)]*\) ', '')
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
     WHERE c.contype = 'f'
       AND c.conrelid = to_regclass(format('public.%I', p_table))
       AND a.attname = p_column;
$fn$;

SELECT is(
    (SELECT string_agg(c.table_name || '.' || c.field_name || ' ' || coalesce(pg_temp.fk_form(c.table_name, c.field_name), '-'),
                       '; ' ORDER BY c.table_name, c.field_name)
       FROM fk_core_columns c),
    (SELECT string_agg(c.table_name || '.' || c.field_name || ' '
                       || coalesce(pg_temp.fk_form('fk_form_probe', c.table_name || '__' || c.field_name), '-'),
                       '; ' ORDER BY c.table_name, c.field_name)
       FROM fk_core_columns c),
    'the seven hand-written core foreign keys have the form the dictionary generates from their fields rows'
);

SELECT * FROM finish();
ROLLBACK;
