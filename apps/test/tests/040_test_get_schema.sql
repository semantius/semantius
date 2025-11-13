-- Test public.get_schema() function
BEGIN;

SELECT plan(18);

-- =====================================================
-- TEST: get_schema() returns correct data for existing table
-- =====================================================
select authenticate_as('user1');

-- Test that get_schema() returns JSON for customers table
SELECT ok(
    (SELECT public.get_schema('customers') IS NOT NULL),
    'get_schema() should return a non-null JSON object for customers table'
);

-- Test table_name
SELECT is(
    (SELECT public.get_schema('customers')->>'table_name'),
    'customers',
    'get_schema() should return table_name "customers"'
);

-- Test singular
SELECT is(
    (SELECT public.get_schema('customers')->>'singular'),
    'customer',
    'get_schema() should return singular "customer"'
);

-- Test plural
SELECT is(
    (SELECT public.get_schema('customers')->>'plural'),
    'customers',
    'get_schema() should return plural "customers"'
);

-- Test singular_label
SELECT is(
    (SELECT public.get_schema('customers')->>'singular_label'),
    'Customer',
    'get_schema() should return singular_label "Customer"'
);

-- Test plural_label
SELECT is(
    (SELECT public.get_schema('customers')->>'plural_label'),
    'Customers',
    'get_schema() should return plural_label "Customers"'
);

-- Test description
SELECT is(
    (SELECT public.get_schema('customers')->>'description'),
    'Customer information and contact details',
    'get_schema() should return correct description'
);

-- Test module_id
SELECT is(
    (SELECT (public.get_schema('customers')->>'module_id')::integer),
    1001,
    'get_schema() should return module_id 1001'
);

-- Test view_permission
SELECT is(
    (SELECT public.get_schema('customers')->>'view_permission'),
    'public:read',
    'get_schema() should return view_permission "public:read"'
);

-- Test edit_permission
SELECT is(
    (SELECT public.get_schema('customers')->>'edit_permission'),
    'sales:manage',
    'get_schema() should return edit_permission "sales:manage"'
);

-- Test id_column
SELECT is(
    (SELECT public.get_schema('customers')->>'id_column'),
    'id',
    'get_schema() should return id_column "id"'
);

-- Test label_column
SELECT is(
    (SELECT public.get_schema('customers')->>'label_column'),
    'customer_name',
    'get_schema() should return label_column "customer_name"'
);

-- Test fields array exists
SELECT ok(
    (SELECT jsonb_typeof((public.get_schema('customers')::jsonb)->'fields') = 'array'),
    'get_schema() should return fields as a JSON array'
);

-- Test fields array is not empty
SELECT ok(
    (SELECT jsonb_array_length((public.get_schema('customers')::jsonb)->'fields') > 0),
    'get_schema() should return non-empty fields array'
);

-- Test fields array contains id field
SELECT ok(
    (SELECT (public.get_schema('customers')::jsonb)->'fields' @> '[{"field_name": "id"}]'::jsonb),
    'get_schema() fields array should contain id field'
);

-- Test fields array contains email field
SELECT ok(
    (SELECT (public.get_schema('customers')::jsonb)->'fields' @> '[{"field_name": "email"}]'::jsonb),
    'get_schema() fields array should contain email field'
);

-- Test that a field has all expected properties
SELECT ok(
    (WITH schema AS (SELECT public.get_schema('customers')::jsonb as data),
     first_field AS (SELECT data->'fields'->0 as field FROM schema)
     SELECT (field ? 'field_name') AND
            (field ? 'label') AND
            (field ? 'data_type') AND
            (field ? 'is_pk') AND
            (field ? 'is_nullable') AND
            (field ? 'field_order')
     FROM first_field),
    'get_schema() fields should have all expected properties'
);

-- =====================================================
-- TEST: get_schema() raises error for non-existing table
-- =====================================================

-- Test that get_schema() raises an error for non-existing table
SELECT throws_ok(
    'SELECT public.get_schema(''nonexistent_table'')',
    '42P01',
    'Table "nonexistent_table" not found in tables metadata',
    'get_schema() should raise an error for non-existing table'
);

SELECT * FROM finish();
ROLLBACK;
