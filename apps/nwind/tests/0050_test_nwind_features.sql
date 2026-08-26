-- =====================================================
-- NORTHWIND FEATURE TESTS (0050)
-- =====================================================
-- The public RPC surface over the nwind model, read as user2 (Northwind
-- Sales): get_schema() reference / children / enum / format / inputMode /
-- composed-label metadata for orders, employees, suppliers, products,
-- order_details and customers; get_module_cubes('nwind'); get_schemas();
-- and get_user_cubes() for user1 (no nwind) vs user2.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(35);

SELECT authenticate_as('user2');

-- =====================================================
-- get_schema('orders'): reference metadata on customer_id
-- =====================================================

-- Test 1
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'format',
    'reference',
    'orders.customer_id should have format reference'
);

-- Test 2
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'reference_table',
    'customers',
    'orders.customer_id reference_table should be customers'
);

-- Test 3
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'reference_table_label_column',
    'company_name',
    'orders.customer_id reference_table_label_column should be company_name'
);

-- Test 4
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'reference_table_singular_label',
    'Customer',
    'orders.customer_id reference_table_singular_label should be Customer'
);

-- Test 5
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'reference_table_plural_label',
    'Customers',
    'orders.customer_id reference_table_plural_label should be Customers'
);

-- Test 6
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'reference_delete_mode',
    'restrict',
    'orders.customer_id reference_delete_mode should be restrict'
);

-- Test 7
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'customer_id'->>'inputMode',
    'required',
    'orders.customer_id inputMode should be required'
);

-- =====================================================
-- get_schema('orders'): children
-- =====================================================

-- Test 8
SELECT ok(
    (public.get_schema('orders')::jsonb)->'children' @> '[{"id": "order_details.order_id"}]'::jsonb,
    'orders children should include order_details.order_id'
);

-- Test 9
SELECT is(
    (SELECT elem->>'singular_label'
     FROM jsonb_array_elements((public.get_schema('orders')::jsonb)->'children') elem
     WHERE elem->>'id' = 'order_details.order_id'),
    'Order Detail',
    'orders child order_details.order_id should carry singular_label "Order Detail"'
);

-- Test 10
SELECT is(
    (SELECT elem->>'plural_label'
     FROM jsonb_array_elements((public.get_schema('orders')::jsonb)->'children') elem
     WHERE elem->>'id' = 'order_details.order_id'),
    'Order Details',
    'orders child order_details.order_id should carry plural_label "Order Details"'
);

-- =====================================================
-- get_schema('orders'): status (required enum with default)
-- =====================================================

-- Test 11
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->>'inputMode',
    'required',
    'orders.status inputMode should be required'
);

-- Test 12
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->>'default',
    'pending',
    'orders.status default should be pending'
);

-- Test 13
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->'enum',
    '["pending", "shipped"]'::jsonb,
    'orders.status enum should be exactly [pending, shipped]'
);

-- Test 14
SELECT ok(
    NOT ((public.get_schema('orders')::jsonb)->'properties'->'status'->'enum' @> '[""]'::jsonb),
    'orders.status enum should not include the empty string (required)'
);

-- Test 15
SELECT ok(
    NOT ((public.get_schema('orders')::jsonb)->'required' @> '["status"]'::jsonb),
    'orders.status should not be listed in the required array (has a non-NULL default)'
);

-- Test 16
SELECT ok(
    NOT ((public.get_schema('orders')::jsonb)->'properties'->'status' ? 'format'),
    'orders.status (enum) should not carry a format key'
);

-- =====================================================
-- get_schema('employees'): optional enum includes ''
-- =====================================================

-- Test 17
SELECT ok(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->'enum' @> '[""]'::jsonb,
    'employees.title_of_courtesy enum should include the empty string (optional)'
);

-- Test 18
SELECT ok(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->'enum'
        @> '["Mr.", "Mrs.", "Ms.", "Dr."]'::jsonb,
    'employees.title_of_courtesy enum should include Mr., Mrs., Ms., Dr.'
);

-- Test 19
SELECT is(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->>'default',
    '',
    'employees.title_of_courtesy default should be the empty string'
);

-- =====================================================
-- string format / readonly / cube_type
-- =====================================================

-- Test 20
SELECT is(
    (public.get_schema('suppliers')::jsonb)->'properties'->'homepage'->>'format',
    'url',
    'suppliers.homepage should have format url'
);

-- Test 21
SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'units_on_order'->>'inputMode',
    'readonly',
    'products.units_on_order inputMode should be readonly'
);

-- Test 22
SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'units_on_order'->>'type',
    'integer',
    'products.units_on_order (int32) should map to JSON type integer'
);

-- Test 23
SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'units_in_stock'->>'cube_type',
    'measure',
    'products.units_in_stock cube_type should be measure'
);

-- =====================================================
-- get_schema('order_details'): composed label discovery
-- =====================================================

-- Test 24
SELECT is(
    (public.get_schema('order_details')::jsonb)->'properties'->'_label'->>'source',
    'order_id',
    'order_details._label source should be order_id (label_parent)'
);

-- Test 25
SELECT is(
    (public.get_schema('order_details')::jsonb)->'properties'->'_label'->>'ctype',
    '_label',
    'order_details._label should have ctype _label'
);

-- Test 26
SELECT is(
    (public.get_schema('order_details')::jsonb)->'properties'->'order_id_label'->>'ctype',
    'fk_label',
    'order_details.order_id_label companion should have ctype fk_label'
);

-- =====================================================
-- get_module_cubes / get_schemas
-- =====================================================

-- Test 27
SELECT set_eq(
    $$SELECT s->'table'->>'table_name' FROM public.get_module_cubes('nwind') AS s$$,
    ARRAY['categories', 'customers', 'employees', 'suppliers', 'products', 'regions',
          'shippers', 'orders', 'territories', 'employee_territories', 'order_details'],
    'get_module_cubes(''nwind'') should return exactly the 11 Northwind tables'
);

-- Test 28
SELECT is(
    json_array_length(public.get_schemas('orders,customers')),
    2,
    'get_schemas(''orders,customers'') should return 2 schemas'
);

-- Test 29
SELECT is(
    (public.get_schemas('orders,customers')::jsonb)->0->>'title',
    'Order',
    'get_schemas(''orders,customers'') element 0 should be the Order schema'
);

-- =====================================================
-- get_schema('customers'): table object
-- =====================================================

-- Test 30
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'view_permission',
    'nwind:view',
    'customers table.view_permission should be nwind:view'
);

-- Test 31
SELECT is(
    ((public.get_schema('customers')::jsonb)->'table'->>'module_id')::integer,
    (SELECT id FROM modules WHERE module_slug = 'nwind'),
    'customers table.module_id should be the Northwind module id'
);

-- Test 32
SELECT is(
    ((public.get_schema('customers')::jsonb)->'table'->>'audit_log')::boolean,
    true,
    'customers table.audit_log should be true'
);

-- Test 33
SELECT is(
    jsonb_array_length((public.get_schema('customers')::jsonb)->'children'),
    0,
    'customers children should be empty (orders.customer_id is a reference, not a parent)'
);

-- =====================================================
-- get_user_cubes(): user1 vs user2
-- =====================================================
SELECT authenticate_as('user1');

-- Test 34
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public.get_user_cubes() AS s
        WHERE s->'table'->>'table_name' IN ('categories', 'customers', 'employees', 'suppliers',
              'products', 'regions', 'shippers', 'orders', 'territories',
              'employee_territories', 'order_details')
    ),
    'user1 get_user_cubes() should not include any Northwind table'
);

SELECT authenticate_as('user2');

-- Test 35
SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_user_cubes() AS s
        WHERE s->'table'->>'table_name' = 'customers'
    ),
    'user2 get_user_cubes() should include customers'
);

SELECT * FROM finish();
ROLLBACK;
