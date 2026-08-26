-- =====================================================
-- NORTHWIND SCHEMA TESTS (0020)
-- =====================================================
-- The shape of the nwind model as built by the DD triggers: the 11 entities
-- and their physical tables, per-entity field sets, label columns, the two
-- junction/child entities, field metadata added by the nwind extensions
-- (enum title_of_courtesy, url homepage, clear reports_to, required
-- customer_id, readonly units_on_order, required status enum with default),
-- FK delete rules, unique and FK indexes, audit triggers, composed-label
-- functions, the physical categories.sort_order order column, the
-- order-insert queue trigger and full-text search on customers.
-- Catalog reads run as user3 (Administrator). Nothing is written.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(67);

SELECT authenticate_as('user3');

-- =====================================================
-- ENTITIES AND TABLES
-- =====================================================

-- Test 1: the module owns exactly the 11 Northwind entities
SELECT set_eq(
    $$SELECT table_name FROM entities
      WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')$$,
    ARRAY['categories', 'customers', 'employees', 'suppliers', 'products', 'regions',
          'shippers', 'orders', 'territories', 'employee_territories', 'order_details'],
    'Northwind module should own exactly the 11 Northwind entities'
);

-- Tests 2-12: physical tables exist
SELECT has_table('public', 'categories', 'categories table should exist');
SELECT has_table('public', 'customers', 'customers table should exist');
SELECT has_table('public', 'employees', 'employees table should exist');
SELECT has_table('public', 'suppliers', 'suppliers table should exist');
SELECT has_table('public', 'products', 'products table should exist');
SELECT has_table('public', 'regions', 'regions table should exist');
SELECT has_table('public', 'shippers', 'shippers table should exist');
SELECT has_table('public', 'orders', 'orders table should exist');
SELECT has_table('public', 'territories', 'territories table should exist');
SELECT has_table('public', 'employee_territories', 'employee_territories table should exist');
SELECT has_table('public', 'order_details', 'order_details table should exist');

-- =====================================================
-- FIELD SETS (auto-created id / label / created_at / updated_at + declared fields)
-- =====================================================

-- Test 13
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'categories'$$,
    ARRAY['id', 'category_name', 'created_at', 'updated_at', 'description'],
    'categories should have exactly id, category_name, created_at, updated_at, description'
);

-- Test 14
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'customers'$$,
    ARRAY['id', 'company_name', 'created_at', 'updated_at', 'customer_id', 'contact_name',
          'contact_title', 'address', 'city', 'region', 'postal_code', 'country', 'phone', 'fax'],
    'customers should have the expected field set'
);

-- Test 15
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'employees'$$,
    ARRAY['id', 'last_name', 'created_at', 'updated_at', 'first_name', 'title', 'title_of_courtesy',
          'birth_date', 'hire_date', 'address', 'city', 'region', 'postal_code', 'country',
          'home_phone', 'extension', 'notes', 'photo_path', 'reports_to'],
    'employees should have the expected field set'
);

-- Test 16
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'suppliers'$$,
    ARRAY['id', 'company_name', 'created_at', 'updated_at', 'contact_name', 'contact_title',
          'address', 'city', 'region', 'postal_code', 'country', 'phone', 'fax', 'homepage'],
    'suppliers should have the expected field set'
);

-- Test 17
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'products'$$,
    ARRAY['id', 'product_name', 'created_at', 'updated_at', 'quantity_per_unit', 'unit_price',
          'units_in_stock', 'units_on_order', 'reorder_level', 'discontinued', 'supplier_id', 'category_id'],
    'products should have the expected field set'
);

-- Test 18
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'regions'$$,
    ARRAY['id', 'region_description', 'created_at', 'updated_at'],
    'regions should have exactly the auto-created fields'
);

-- Test 19
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'shippers'$$,
    ARRAY['id', 'company_name', 'created_at', 'updated_at', 'phone'],
    'shippers should have exactly id, company_name, created_at, updated_at, phone'
);

-- Test 20
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'orders'$$,
    ARRAY['id', 'ship_name', 'created_at', 'updated_at', 'status', 'ship_address', 'ship_city',
          'ship_region', 'ship_postal_code', 'ship_country', 'freight', 'order_date', 'required_date',
          'shipped_date', 'customer_id', 'employee_id', 'ship_via'],
    'orders should have the expected field set'
);

-- Test 21
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'territories'$$,
    ARRAY['id', 'territory_description', 'created_at', 'updated_at', 'territory_id', 'region_id'],
    'territories should have exactly id, territory_description, created_at, updated_at, territory_id, region_id'
);

-- Test 22
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'employee_territories'$$,
    ARRAY['id', 'label', 'created_at', 'updated_at', 'employee_id', 'territory_id'],
    'employee_territories should have exactly id, label, created_at, updated_at, employee_id, territory_id'
);

-- Test 23
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'order_details'$$,
    ARRAY['id', 'label', 'created_at', 'updated_at', 'order_id', 'product_id', 'unit_price', 'quantity', 'discount'],
    'order_details should have the expected field set'
);

-- =====================================================
-- LABEL COLUMNS, CHILD / JUNCTION CLASSIFICATION
-- =====================================================

-- Test 24: label_column per entity
SELECT set_eq(
    $$SELECT table_name || ':' || label_column FROM entities
      WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')$$,
    ARRAY['categories:category_name', 'customers:company_name', 'employees:last_name',
          'suppliers:company_name', 'products:product_name', 'regions:region_description',
          'shippers:company_name', 'orders:ship_name', 'territories:territory_description',
          'employee_territories:label', 'order_details:label'],
    'Every Northwind entity should have the expected label_column'
);

-- Test 25: the two parent-keyed entities are children
SELECT set_eq(
    $$SELECT table_name FROM entities
      WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind') AND is_child$$,
    ARRAY['employee_territories', 'order_details'],
    'employee_territories and order_details should be the only child entities (parent format fields)'
);

-- Test 26: employee_territories is a pure junction
SELECT is(
    (SELECT entity_type FROM entities WHERE table_name = 'employee_territories'),
    'junction',
    'employee_territories should have entity_type = junction'
);

-- Test 27: order_details carries payload, so it is not a junction
SELECT isnt(
    (SELECT entity_type FROM entities WHERE table_name = 'order_details'),
    'junction',
    'order_details (junction with payload) should not have entity_type = junction'
);

-- =====================================================
-- FIELD METADATA (nwind extensions)
-- =====================================================

-- Test 28: title_of_courtesy is an enum
SELECT is(
    (SELECT format FROM fields WHERE table_name = 'employees' AND field_name = 'title_of_courtesy'),
    'enum',
    'employees.title_of_courtesy should have format enum'
);

-- Test 29: with the four courtesy titles
SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'employees' AND field_name = 'title_of_courtesy'),
    '["Mr.", "Mrs.", "Ms.", "Dr."]'::jsonb,
    'employees.title_of_courtesy enum_values should be [Mr., Mrs., Ms., Dr.]'
);

-- Test 30: optional with empty default
SELECT ok(
    (SELECT input_type = 'default' AND default_value = ''
     FROM fields WHERE table_name = 'employees' AND field_name = 'title_of_courtesy'),
    'employees.title_of_courtesy should be optional (input_type default) with default_value empty'
);

-- Test 31: homepage is a url
SELECT is(
    (SELECT format FROM fields WHERE table_name = 'suppliers' AND field_name = 'homepage'),
    'url',
    'suppliers.homepage should have format url'
);

-- Test 32: reports_to is a self-reference
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'employees' AND field_name = 'reports_to'),
    'employees',
    'employees.reports_to should reference employees'
);

-- Test 33: with delete mode clear
SELECT is(
    (SELECT reference_delete_mode FROM fields WHERE table_name = 'employees' AND field_name = 'reports_to'),
    'clear',
    'employees.reports_to reference_delete_mode should be clear'
);

-- Test 34: orders.customer_id references customers
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'orders' AND field_name = 'customer_id'),
    'customers',
    'orders.customer_id should reference customers table'
);

-- Test 35: required, restrict
SELECT ok(
    (SELECT input_type = 'required' AND reference_delete_mode = 'restrict'
     FROM fields WHERE table_name = 'orders' AND field_name = 'customer_id'),
    'orders.customer_id should be required with reference_delete_mode restrict'
);

-- Test 36: products.category_id references categories
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'products' AND field_name = 'category_id'),
    'categories',
    'products.category_id should reference categories table'
);

-- Test 37: products.supplier_id references suppliers
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'products' AND field_name = 'supplier_id'),
    'suppliers',
    'products.supplier_id should reference suppliers table'
);

-- Test 38: units_on_order is readonly
SELECT is(
    (SELECT input_type FROM fields WHERE table_name = 'products' AND field_name = 'units_on_order'),
    'readonly',
    'products.units_on_order should have input_type readonly'
);

-- Test 39: orders.status is an enum
SELECT is(
    (SELECT format FROM fields WHERE table_name = 'orders' AND field_name = 'status'),
    'enum',
    'orders.status should have format enum'
);

-- Test 40: with pending / shipped
SELECT is(
    (SELECT enum_values FROM fields WHERE table_name = 'orders' AND field_name = 'status'),
    '["pending", "shipped"]'::jsonb,
    'orders.status enum_values should be [pending, shipped]'
);

-- Test 41: required with default pending
SELECT ok(
    (SELECT input_type = 'required' AND default_value = 'pending'
     FROM fields WHERE table_name = 'orders' AND field_name = 'status'),
    'orders.status should be required with default_value pending'
);

-- Test 42: parent legs of the two junctions
SELECT set_eq(
    $$SELECT table_name || '.' || field_name FROM fields
      WHERE format = 'parent'
        AND table_name IN (SELECT table_name FROM entities
                           WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind'))$$,
    ARRAY['employee_territories.employee_id', 'employee_territories.territory_id',
          'order_details.order_id', 'order_details.product_id'],
    'Exactly the four junction legs should have format parent'
);

-- Test 43: unique_value fields (original text PKs)
SELECT set_eq(
    $$SELECT table_name || '.' || field_name FROM fields
      WHERE unique_value
        AND table_name IN (SELECT table_name FROM entities
                           WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind'))$$,
    ARRAY['customers.customer_id', 'territories.territory_id'],
    'customers.customer_id and territories.territory_id should be the only unique_value fields'
);

-- Test 44: wide searchable description on categories
SELECT ok(
    (SELECT width = 'w' AND searchable
     FROM fields WHERE table_name = 'categories' AND field_name = 'description'),
    'categories.description should be searchable with width w'
);

-- Test 45: CURRENT_DATE defaults
SELECT set_eq(
    $$SELECT table_name || '.' || field_name FROM fields
      WHERE format = 'date' AND default_value = 'CURRENT_DATE'
        AND table_name IN ('employees', 'orders')$$,
    ARRAY['employees.hire_date', 'orders.order_date', 'orders.required_date'],
    'hire_date, order_date and required_date should default to CURRENT_DATE'
);

-- Test 46: units_in_stock is a cube measure
SELECT is(
    (SELECT cube_type FROM fields WHERE table_name = 'products' AND field_name = 'units_in_stock'),
    'measure',
    'products.units_in_stock should have cube_type measure'
);

-- =====================================================
-- FOREIGN KEYS AND INDEXES
-- =====================================================

-- Test 47: reports_to FK is ON DELETE SET NULL
SELECT is(
    (SELECT confdeltype::text FROM pg_constraint WHERE conname = 'employees_reports_to_fkey'),
    'n',
    'employees_reports_to_fkey should be ON DELETE SET NULL (clear)'
);

-- Test 48: all orders FKs are ON DELETE RESTRICT
SELECT set_eq(
    $$SELECT conname::text FROM pg_constraint
      WHERE contype = 'f' AND conrelid = 'public.orders'::regclass AND confdeltype = 'r'$$,
    ARRAY['orders_customer_id_fkey', 'orders_employee_id_fkey', 'orders_ship_via_fkey'],
    'orders should have exactly three RESTRICT foreign keys'
);

-- Test 49: unique index for the customer code
SELECT has_index('public', 'customers', 'customers_customer_id_unique',
    'Unique index customers_customer_id_unique should exist for text customer codes');

-- Test 50: unique index for the territory code
SELECT has_index('public', 'territories', 'territories_territory_id_unique',
    'Unique index territories_territory_id_unique should exist for text territory codes');

-- Test 51: one idx_<table>_<fk> index per FK field
SELECT set_eq(
    $$SELECT indexname::text FROM pg_indexes
      WHERE schemaname = 'public' AND indexname LIKE 'idx\_%'
        AND tablename IN (SELECT table_name FROM entities
                          WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind'))$$,
    ARRAY['idx_employees_reports_to', 'idx_products_supplier_id', 'idx_products_category_id',
          'idx_orders_customer_id', 'idx_orders_employee_id', 'idx_orders_ship_via',
          'idx_territories_region_id', 'idx_employee_territories_employee_id',
          'idx_employee_territories_territory_id', 'idx_order_details_order_id',
          'idx_order_details_product_id'],
    'Every reference/parent field should have its idx_<table>_<field> index'
);

-- =====================================================
-- AUDIT LOG
-- =====================================================

-- Test 52: audit_log only on customers and products
SELECT set_eq(
    $$SELECT table_name FROM entities
      WHERE audit_log AND module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')$$,
    ARRAY['customers', 'products'],
    'audit_log should be TRUE only on customers and products'
);

-- Test 53
SELECT has_trigger('public', 'customers', 'audit_i_u_d', 'customers should have the audit_i_u_d trigger');
-- Test 54
SELECT has_trigger('public', 'products', 'audit_i_u_d', 'products should have the audit_i_u_d trigger');
-- Test 55
SELECT hasnt_trigger('public', 'orders', 'audit_i_u_d', 'orders should not have the audit_i_u_d trigger');

-- =====================================================
-- COMPOSED LABELS
-- =====================================================

-- Test 56: label_parent spines
SELECT set_eq(
    $$SELECT table_name || ':' || label_parent FROM entities
      WHERE label_parent <> ''
        AND module_id = (SELECT id FROM modules WHERE module_slug = 'nwind')$$,
    ARRAY['territories:region_id', 'order_details:order_id'],
    'territories and order_details should be the only entities with a label_parent'
);

-- Test 57: a _label(<table>) function exists for every entity
SELECT set_eq(
    $$SELECT proargtypes[0]::regtype::text FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace AND proname = '_label'
        AND proargtypes[0]::regtype::text IN (SELECT table_name FROM entities
              WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind'))$$,
    ARRAY['categories', 'customers', 'employees', 'suppliers', 'products', 'regions',
          'shippers', 'orders', 'territories', 'employee_territories', 'order_details'],
    'Every Northwind entity should have a generated _label() function'
);

-- Test 58: a <fk>_label companion exists for every reference/parent field
SELECT set_eq(
    $$SELECT proname || '(' || proargtypes[0]::regtype::text || ')' FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace AND proname LIKE '%\_label' AND proname <> '_label'
        AND proargtypes[0]::regtype::text IN (SELECT table_name FROM entities
              WHERE module_id = (SELECT id FROM modules WHERE module_slug = 'nwind'))$$,
    ARRAY['reports_to_label(employees)', 'supplier_id_label(products)', 'category_id_label(products)',
          'customer_id_label(orders)', 'employee_id_label(orders)', 'ship_via_label(orders)',
          'region_id_label(territories)', 'employee_id_label(employee_territories)',
          'territory_id_label(employee_territories)', 'order_id_label(order_details)',
          'product_id_label(order_details)'],
    'Every reference/parent field should have a generated <fk>_label() companion'
);

-- =====================================================
-- ORDER COLUMN (physical column, no fields row)
-- =====================================================

-- Test 59
SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'categories'),
    'sort_order',
    'categories.order_column should be sort_order'
);

-- Test 60
SELECT has_column('public', 'categories', 'sort_order', 'categories should have a physical sort_order column');

-- Test 61
SELECT col_type_is('public', 'categories', 'sort_order', 'integer', 'categories.sort_order should be an integer column');

-- Test 62
SELECT has_trigger('public', 'categories', 'zz_auto_order_categories',
    'categories should have the zz_auto_order_categories auto-assign trigger');

-- Test 63: the order column is not a declared field
SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'categories' AND field_name = 'sort_order'),
    0,
    'categories.sort_order should not have a fields row (provisioned by order_column)'
);

-- =====================================================
-- QUEUE TRIGGER AND FULL-TEXT SEARCH
-- =====================================================

-- Test 64
SELECT has_trigger('public', 'orders', 'queue_events_insert_on_orders',
    'orders should have the queue_events_insert_on_orders trigger');

-- Test 65
SELECT has_column('public', 'customers', 'search_vector', 'customers should have a search_vector column');

-- Test 66
SELECT has_index('public', 'customers', 'customers_search_vector_idx',
    'customers should have the GIN index customers_search_vector_idx');

-- Test 67: searchable customer fields
SELECT set_eq(
    $$SELECT field_name FROM fields WHERE table_name = 'customers' AND searchable$$,
    ARRAY['company_name', 'customer_id', 'contact_name', 'city', 'country'],
    'customers searchable fields should be company_name, customer_id, contact_name, city, country'
);

SELECT * FROM finish();
ROLLBACK;
