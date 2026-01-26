-- Test public.get_schema() function
BEGIN;

SELECT plan(77);

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
            (prop ? 'inputMode') AND
            (prop ? 'width')
     FROM id_property),
    'get_schema() properties should have all expected fields (type, title, description, inputMode, width)'
);

-- Test required array exists
SELECT ok(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'required') = 'array',
    'get_schema() should return required as a JSON array'
);

-- Test required array does NOT contain id (id is auto-generated, not required for INSERT)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'required' @> '["id"]'::jsonb),
    'get_schema() required array should NOT contain id field (auto-generated)'
);

-- Test required array does NOT contain created_at (auto-maintained by triggers)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'required' @> '["created_at"]'::jsonb),
    'get_schema() required array should NOT contain created_at field (auto-maintained)'
);

-- Test required array does NOT contain updated_at (auto-maintained by triggers)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'required' @> '["updated_at"]'::jsonb),
    'get_schema() required array should NOT contain updated_at field (auto-maintained)'
);

-- Test required array contains customer_name (label_column, which is required)
SELECT ok(
    (public.get_schema('customers')::jsonb)->'required' @> '["customer_name"]'::jsonb,
    'get_schema() required array should contain customer_name field (label_column)'
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

-- Verify user1 doesn't have admin permission
SELECT ok(
    NOT rbac.has_permission('admin'),
    'user1 should not have admin permission'
);

-- Test that get_schema() raises "not found" error for webhook_receivers table (requires admin)
-- This prevents leaking information about table existence
SELECT throws_ok(
    'SELECT public.get_schema(''webhook_receivers'')',
    '42P01',
    'Table "webhook_receivers" not found in tables metadata',
    'get_schema() should raise "not found" error when user lacks view permission'
);

-- =====================================================
-- TEST: New fields (inputType, width, format)
-- =====================================================

select authenticate_as('user1');

-- Test inputMode field exists and has correct value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'inputMode',
    'readonly',
    'get_schema() should return correct inputMode for id field'
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

-- =====================================================
-- TEST: New features - fieldOrder, enum, default empty strings
-- =====================================================

-- Test fieldOrder exists in all properties
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'id' ? 'fieldOrder',
    'get_schema() should include fieldOrder field in id property'
);

SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'id'->>'fieldOrder')::INTEGER,
    0,
    'get_schema() should return correct fieldOrder for id field (0)'
);

SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'email'->>'fieldOrder')::INTEGER,
    10,
    'get_schema() should return correct fieldOrder for email field (10)'
);

-- Test that int32 format does NOT appear in output (only type: integer)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'properties'->'id' ? 'format'),
    'get_schema() should NOT include format field for int32 (only type: integer)'
);

SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'properties'->'total_orders' ? 'format'),
    'get_schema() should NOT include format field for int32 total_orders'
);

-- Test enum support for status field
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'status' ? 'enum',
    'get_schema() should include enum field for status property'
);

SELECT is(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'properties'->'status'->'enum'),
    'array',
    'get_schema() enum field should be an array'
);

SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'status'->'enum' @> '["active"]'::jsonb,
    'get_schema() enum array should contain "active"'
);

SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'status'->'enum' @> '["inactive"]'::jsonb,
    'get_schema() enum array should contain "inactive"'
);

-- Test that enum fields do NOT include format property
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'properties'->'status' ? 'format'),
    'get_schema() should NOT include format field for enum fields'
);

-- Test default empty string for string fields
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'phone'->>'default',
    '',
    'get_schema() should return default empty string for phone field'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'customer_name'->>'default',
    '',
    'get_schema() should return default empty string for customer_name field'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'company'->>'default',
    '',
    'get_schema() should return default empty string for company field'
);

-- Test that status has both enum and default value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'status'->>'default',
    'active',
    'get_schema() should return default "active" for status field'
);

-- =====================================================
-- TEST: created_at and updated_at fields in properties
-- =====================================================

-- Test that created_at field exists in properties
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties' ? 'created_at',
    'get_schema() properties should contain created_at field'
);

-- Test that updated_at field exists in properties
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties' ? 'updated_at',
    'get_schema() properties should contain updated_at field'
);

-- Test created_at has correct type
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'created_at'->>'type',
    'string',
    'get_schema() created_at should have type string'
);

-- Test created_at has format date-time
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'created_at'->>'format',
    'date-time',
    'get_schema() created_at should have format date-time'
);

-- Test created_at has correct inputMode
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'created_at'->>'inputMode',
    'disabled',
    'get_schema() created_at should have inputMode disabled'
);

-- Test updated_at has correct type
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'updated_at'->>'type',
    'string',
    'get_schema() updated_at should have type string'
);

-- Test updated_at has format date-time
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'updated_at'->>'format',
    'date-time',
    'get_schema() updated_at should have format date-time'
);

-- Test updated_at has correct inputMode
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'updated_at'->>'inputMode',
    'disabled',
    'get_schema() updated_at should have inputMode disabled'
);

-- =====================================================
-- TEST: company field has correct field order (20)
-- =====================================================

-- Test that company field has fieldOrder 20
SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'company'->>'fieldOrder')::INTEGER,
    20,
    'get_schema() should return fieldOrder 20 for company field'
);

-- Test that phone field has fieldOrder 30 (swapped with company)
SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'phone'->>'fieldOrder')::INTEGER,
    30,
    'get_schema() should return fieldOrder 30 for phone field'
);

-- =====================================================
-- TEST: is_core fields (id, label, created_at, updated_at)
-- =====================================================

-- Test that id field is marked as is_core
SELECT is(
    (SELECT is_core FROM fields WHERE table_name = 'customers' AND field_name = 'id'),
    TRUE,
    'id field should be marked as is_core = TRUE'
);

-- Test that customer_name (label) field is marked as is_core
SELECT is(
    (SELECT is_core FROM fields WHERE table_name = 'customers' AND field_name = 'customer_name'),
    TRUE,
    'customer_name (label) field should be marked as is_core = TRUE'
);

-- Test that created_at field is marked as is_core
SELECT is(
    (SELECT is_core FROM fields WHERE table_name = 'customers' AND field_name = 'created_at'),
    TRUE,
    'created_at field should be marked as is_core = TRUE'
);

-- Test that updated_at field is marked as is_core
SELECT is(
    (SELECT is_core FROM fields WHERE table_name = 'customers' AND field_name = 'updated_at'),
    TRUE,
    'updated_at field should be marked as is_core = TRUE'
);

-- Test that non-core fields (like email) are marked as is_core = FALSE
SELECT is(
    (SELECT is_core FROM fields WHERE table_name = 'customers' AND field_name = 'email'),
    FALSE,
    'email field should be marked as is_core = FALSE'
);

-- Switch to admin user for mutation tests
select authenticate_as('user3');

-- Test that attempting to delete a core field (created_at) raises an error
SELECT throws_ok(
    'DELETE FROM fields WHERE table_name = ''customers'' AND field_name = ''created_at''',
    'P0001',
    'Cannot delete core system field "created_at". Core fields (id, label, created_at, updated_at) cannot be deleted.',
    'Deleting created_at field should raise an exception'
);

-- Test that attempting to delete a core field (id) raises an error
SELECT throws_ok(
    'DELETE FROM fields WHERE table_name = ''customers'' AND field_name = ''id''',
    'P0001',
    'Cannot delete core system field "id". Core fields (id, label, created_at, updated_at) cannot be deleted.',
    'Deleting id field should raise an exception'
);

-- Test that attempting to change format of a core field raises an error
SELECT throws_ok(
    'UPDATE fields SET format = ''text'' WHERE table_name = ''customers'' AND field_name = ''created_at''',
    'P0001',
    'Cannot change format of core system field "created_at"',
    'Changing format of created_at field should raise an exception'
);

-- Test that attempting to change nullable constraint of a core field raises an error
SELECT throws_ok(
    'UPDATE fields SET is_nullable = TRUE WHERE table_name = ''customers'' AND field_name = ''id''',
    'P0001',
    'Cannot change nullable constraint of core system field "id"',
    'Changing nullable constraint of id field should raise an exception'
);

-- Test that metadata updates to core fields are allowed (title, description)
SELECT lives_ok(
    'UPDATE fields SET title = ''Record ID'', description = ''Unique identifier'' WHERE table_name = ''customers'' AND field_name = ''id''',
    'Updating title and description of core field should succeed'
);

-- =====================================================
-- TEST: Properties ordering by fieldOrder
-- =====================================================

select authenticate_as('user1');

-- Test that properties keys are ordered by fieldOrder value
-- Since JSON maintains insertion order but JSONB doesn't, we test by checking
-- that each key appears before the next key in the text representation
WITH schema_text AS (
    SELECT public.get_schema('customers')::text AS schema_str
),
expected_order AS (
    SELECT array_agg(field_name ORDER BY field_order) AS ordered_fields
    FROM fields
    WHERE table_name = 'customers'
),
key_positions AS (
    SELECT 
        field_name,
        field_order,
        position('"' || field_name || '":' IN (SELECT schema_str FROM schema_text)) AS key_position
    FROM fields
    WHERE table_name = 'customers'
    ORDER BY field_order
)
SELECT is(
    (SELECT array_agg(field_name ORDER BY key_position) FROM key_positions),
    (SELECT ordered_fields FROM expected_order),
    'get_schema() properties keys should be ordered by fieldOrder value (verified via text position)'
);

SELECT * FROM finish();
ROLLBACK;
