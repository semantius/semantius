-- Test public.get_schema() function
BEGIN;

SELECT plan(39);

-- =====================================================
-- TEST: get_schema() returns correct data for existing table
-- =====================================================
select authenticate_as('user1');

-- Test that get_schema() returns JSON for customers table
SELECT ok(
    public.get_schema('customers') IS NOT NULL,
    'get_schema() should return a non-null JSON object for customers table'
);

-- Test $schema field
SELECT is(
    public.get_schema('customers')->>'$schema',
    'https://semantius.com/meta/sem-schema/v1',
    'get_schema() should return $schema field'
);

-- Test $id field
SELECT is(
    public.get_schema('customers')->>'$id',
    'https://example.com/schemas/customers.schema.json',
    'get_schema() should return $id field with table name'
);

-- Test type field
SELECT is(
    public.get_schema('customers')->>'type',
    'object',
    'get_schema() should return type "object"'
);

-- Test title field
SELECT is(
    public.get_schema('customers')->>'title',
    'Customer',
    'get_schema() should return title from singular_label'
);

-- Test description field
SELECT is(
    public.get_schema('customers')->>'description',
    'Customer information and contact details',
    'get_schema() should return correct description'
);

-- Test additionalProperties field
SELECT is(
    (public.get_schema('customers')->>'additionalProperties')::boolean,
    false,
    'get_schema() should return additionalProperties as false'
);

-- Test table object exists
SELECT ok(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'table') = 'object',
    'get_schema() should return table as a JSON object'
);

-- Test table.table_name
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'table_name',
    'customers',
    'get_schema() table object should contain table_name "customers"'
);

-- Test table.singular
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'singular',
    'customer',
    'get_schema() table object should contain singular "customer"'
);

-- Test table.plural
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'plural',
    'customers',
    'get_schema() table object should contain plural "customers"'
);

-- Test table.singular_label
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'singular_label',
    'Customer',
    'get_schema() table object should contain singular_label "Customer"'
);

-- Test table.plural_label
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'plural_label',
    'Customers',
    'get_schema() table object should contain plural_label "Customers"'
);

-- Test table.description
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'description',
    'Customer information and contact details',
    'get_schema() table object should contain correct description'
);

-- Test table.module_id
SELECT is(
    ((public.get_schema('customers')::jsonb)->'table'->>'module_id')::INTEGER,
    1001,
    'get_schema() table object should contain module_id'
);

-- Test table.view_permission
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'view_permission',
    'public:read',
    'get_schema() table object should contain view_permission'
);

-- Test table.edit_permission
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'edit_permission',
    'sales:manage',
    'get_schema() table object should contain edit_permission'
);

-- Test table.id_column
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'id_column',
    'id',
    'get_schema() table object should contain id_column'
);

-- Test table.label_column
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'label_column',
    'customer_name',
    'get_schema() table object should contain label_column'
);

-- Test table.created_at exists (timestamp field)
SELECT ok(
    (public.get_schema('customers')::jsonb)->'table' ? 'created_at',
    'get_schema() table object should contain created_at field'
);

-- Test table.updated_at exists (timestamp field)
SELECT ok(
    (public.get_schema('customers')::jsonb)->'table' ? 'updated_at',
    'get_schema() table object should contain updated_at field'
);

-- Test properties object exists
SELECT ok(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'properties') = 'object',
    'get_schema() should return properties as a JSON object'
);

-- Test properties object is not empty
SELECT ok(
    (SELECT count(*) > 0 FROM jsonb_object_keys((public.get_schema('customers')::jsonb)->'properties')),
    'get_schema() should return non-empty properties object'
);

-- Test properties contains id field
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties' ? 'id',
    'get_schema() properties should contain id property'
);

-- Test properties contains email field
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties' ? 'email',
    'get_schema() properties should contain email property'
);

-- Test that a property has expected structure
SELECT ok(
    (WITH schema AS (SELECT public.get_schema('customers')::jsonb as data),
     id_property AS (SELECT data->'properties'->'id' as prop FROM schema)
     SELECT (prop ? 'type') AND
            (prop ? 'title') AND
            (prop ? 'description') AND
            (prop ? 'inputType') AND
            (prop ? 'width')
     FROM id_property),
    'get_schema() properties should have all expected fields (type, title, description, inputType, width)'
);

-- Test required array exists
SELECT ok(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'required') = 'array',
    'get_schema() should return required as a JSON array'
);

-- Test required array contains id
SELECT ok(
    (public.get_schema('customers')::jsonb)->'required' @> '["id"]'::jsonb,
    'get_schema() required array should contain id field'
);

-- =====================================================
-- TEST: get_schema() raises error for non-existing table
-- =====================================================

-- Test that get_schema() raises an error for non-existing table
SELECT throws_ok(
    'SELECT public.get_schema(''nonexistent_table'')',
    '42P01',
    'Table "nonexistent_table" not found in tables',
    'get_schema() should raise an error for non-existing table'
);

-- =====================================================
-- TEST: get_schema() raises error when user lacks view permission
-- =====================================================

-- Test case: user1 has the User role (public:read, user:read) but NOT sales:read
-- user1 should not be able to access products table which requires sales:read

select authenticate_as('user1');

-- Verify user1 doesn't have sales:read permission
SELECT ok(
    NOT rbac.has_permission('sales:read'),
    'user1 should not have sales:read permission'
);

-- Test that get_schema() raises "not found" error for products table (requires sales:read)
-- This prevents leaking information about table existence
SELECT throws_ok(
    'SELECT public.get_schema(''products'')',
    '42P01',
    'Table "products" not found in tables metadata',
    'get_schema() should raise "not found" error when user lacks view permission'
);

-- =====================================================
-- TEST: New fields (inputType, width, format)
-- =====================================================

select authenticate_as('user1');

-- Test inputType field exists and has correct value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'inputType',
    'readonly',
    'get_schema() should return correct inputType for id field'
);

-- Test width field exists and has correct value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'width',
    's',
    'get_schema() should return correct width for id field'
);

-- Test format field for email (should have format)
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'email' ? 'format',
    'get_schema() should include format field for email property'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'email'->>'format',
    'email',
    'get_schema() should return format "email" for email field'
);

-- Test format field is not present for primitive types
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'properties'->'customer_name' ? 'format'),
    'get_schema() should not include format field for plain text fields'
);

-- Test integer type mapping
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'type',
    'integer',
    'get_schema() should map int32 format to integer type'
);

-- Test boolean type mapping
SELECT is(
    (public.get_schema('employees')::jsonb)->'properties'->'is_active'->>'type',
    'boolean',
    'get_schema() should map boolean format to boolean type'
);

-- Test number type mapping for double
SELECT is(
    (public.get_schema('employees')::jsonb)->'properties'->'salary'->>'type',
    'number',
    'get_schema() should map double format to number type'
);

-- Test that default field with proper type conversion exists for non-null fields with defaults
-- Note: Most test data fields don't have explicit default_value set
-- This tests the structure is correct when defaults exist

SELECT * FROM finish();
ROLLBACK;
