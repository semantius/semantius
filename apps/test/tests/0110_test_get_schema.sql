-- Test public.get_schema() function
--
-- Fixtures: the persisted nwind module — customers / orders / products / suppliers /
-- employees / order_details (all view_permission 'nwind:view', edit_permission
-- 'nwind:manage') — plus ONE ephemeral entity `sch_probe` created in-tx as user3
-- (module _core, public:read / admin, managed) carrying an `email` and a `double`
-- field: formats Northwind has no natural counterpart for (format emission,
-- double → JSON number).
--
-- Readers: user2 (northwind_sales → nwind:view) for data/schema reads,
--          user3 (Administrator) for catalog mutations and the probe,
--          user1 (no nwind:view, no admin) only for the permission-gating negatives.
-- Module/role/permission ids are never hard-coded (the nwind module reuses the id the old CRM module had).
BEGIN;

SELECT plan(155);

-- =====================================================
-- SETUP (user3): resolve the nwind module id, create the ephemeral probe
-- =====================================================
select authenticate_as('user3');

-- modules is filtered by view_permission — resolve the id once as admin, never hard-code it
CREATE TEMP TABLE sch_ids AS
SELECT id AS nwind_module_id FROM modules WHERE module_slug = 'nwind';

-- Ephemeral probe entity: email (string format emission) + double (→ JSON number)
INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES (
    'sch_probe', 'sch_probe', 'sch_probe', 'Schema Probe', 'Schema Probes',
    'Ephemeral probe for get_schema() format emission',
    1, 'public:read', 'admin', 'id', 'label', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
VALUES ('sch_probe', 'contact_email', 'Contact Email', 'email',  'default', 30),
       ('sch_probe', 'ratio',         'Ratio',         'double', 'default', 40);

-- =====================================================
-- TEST: get_schema() returns correct data for existing table
-- =====================================================
select authenticate_as('user2');

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

-- Test table.module_id (the nwind module, resolved by slug — never the literal id)
SELECT is(
    ((public.get_schema('customers')::jsonb)->'table'->>'module_id')::INTEGER,
    (SELECT nwind_module_id FROM sch_ids),
    'get_schema() table object should contain module_id of the nwind module'
);

-- Test table.view_permission
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'view_permission',
    'nwind:view',
    'get_schema() table object should contain view_permission'
);

-- Test table.edit_permission
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'edit_permission',
    'nwind:manage',
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
    'company_name',
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

-- Test properties contains customer_id field
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties' ? 'customer_id',
    'get_schema() properties should contain customer_id property'
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

-- Test required array does NOT contain company_name (label column, has default value)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'required' @> '["company_name"]'::jsonb),
    'get_schema() required array should NOT contain company_name field (has default value)'
);

-- =====================================================
-- TEST: get_schema() raises error for non-existing table
-- =====================================================

select authenticate_as('user1');

-- Test that get_schema() raises an error for non-existing table
SELECT throws_ok(
    'SELECT public.get_schema(''nonexistent_table'')',
    '42P01',
    'Table "nonexistent_table" not found in entities',
    'get_schema() should raise an error for non-existing table'
);

-- =====================================================
-- TEST: get_schema() raises error when user lacks view permission
-- =====================================================

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

select authenticate_as('user2');

-- Test input_mode field exists and has correct value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'inputMode',
    'readonly',
    'get_schema() should return correct inputMode for id field'
);

-- Test width field exists and has correct value
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'width',
    'default',
    'get_schema() should return correct width for id field'
);

-- Test format field for email (should have format) — ephemeral probe, Northwind has no email field
SELECT ok(
    (public.get_schema('sch_probe')::jsonb)->'properties'->'contact_email' ? 'format',
    'get_schema() should include format field for email property'
);

SELECT is(
    (public.get_schema('sch_probe')::jsonb)->'properties'->'contact_email'->>'format',
    'email',
    'get_schema() should return format "email" for email field'
);

-- Test format field is present for plain text fields (format: text is now returned)
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'company_name' ? 'format',
    'get_schema() should include format field for plain text fields'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'company_name'->>'format',
    'text',
    'get_schema() should return format "text" for plain text fields'
);

-- Test string format emission on persisted data (suppliers.homepage is a url)
SELECT is(
    (public.get_schema('suppliers')::jsonb)->'properties'->'homepage'->>'format',
    'url',
    'get_schema() should return format "url" for suppliers.homepage'
);

-- Test integer type mapping
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'type',
    'integer',
    'get_schema() should map int32 format to integer type'
);

-- Test boolean type mapping
SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'discontinued'->>'type',
    'boolean',
    'get_schema() should map boolean format to boolean type'
);

-- Test number type mapping for double — ephemeral probe, Northwind has no double field
SELECT is(
    (public.get_schema('sch_probe')::jsonb)->'properties'->'ratio'->>'type',
    'number',
    'get_schema() should map double format to number type'
);

SELECT ok(
    NOT ((public.get_schema('sch_probe')::jsonb)->'properties'->'ratio' ? 'format'),
    'get_schema() should NOT include format field for double (type mapper only)'
);

-- Test number type mapping for the number format (orders.freight)
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'freight'->>'type',
    'number',
    'get_schema() should map number format to number type'
);

-- Test readonly inputMode on a non-core field (products.units_on_order)
SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'units_on_order'->>'inputMode',
    'readonly',
    'get_schema() should return inputMode "readonly" for products.units_on_order'
);

-- Test that default field with proper type conversion exists for non-null fields with defaults
-- Note: Most customers fields don't have explicit default_value set
-- This tests the structure is correct when defaults exist

-- =====================================================
-- TEST: New features - field_order, enum, default empty strings
-- =====================================================

-- Test field_order exists in all properties
SELECT ok(
    (public.get_schema('customers')::jsonb)->'properties'->'id' ? 'field_order',
    'get_schema() should include field_order field in id property'
);

SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'id'->>'field_order')::INTEGER,
    10,
    'get_schema() should return correct field_order for id field (10)'
);

SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'customer_id'->>'field_order')::INTEGER,
    30,
    'get_schema() should return correct field_order for customer_id field (30)'
);

-- Test that int32 format does NOT appear in output (only type: integer)
SELECT ok(
    NOT ((public.get_schema('customers')::jsonb)->'properties'->'id' ? 'format'),
    'get_schema() should NOT include format field for int32 (only type: integer)'
);

SELECT ok(
    NOT ((public.get_schema('products')::jsonb)->'properties'->'units_in_stock' ? 'format'),
    'get_schema() should NOT include format field for int32 units_in_stock'
);

-- Test enum support for orders.status field
SELECT ok(
    (public.get_schema('orders')::jsonb)->'properties'->'status' ? 'enum',
    'get_schema() should include enum field for status property'
);

SELECT is(
    jsonb_typeof((public.get_schema('orders')::jsonb)->'properties'->'status'->'enum'),
    'array',
    'get_schema() enum field should be an array'
);

SELECT ok(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->'enum' @> '["pending"]'::jsonb,
    'get_schema() enum array should contain "pending"'
);

SELECT ok(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->'enum' @> '["shipped"]'::jsonb,
    'get_schema() enum array should contain "shipped"'
);

-- Test that enum fields do NOT include format property
SELECT ok(
    NOT ((public.get_schema('orders')::jsonb)->'properties'->'status' ? 'format'),
    'get_schema() should NOT include format field for enum fields'
);

-- Test default empty string for string fields
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'phone'->>'default',
    '',
    'get_schema() should return default empty string for phone field'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'company_name'->>'default',
    '',
    'get_schema() should return default empty string for company_name field'
);

SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'contact_name'->>'default',
    '',
    'get_schema() should return default empty string for contact_name field'
);

-- Test that status has both enum and default value
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->>'default',
    'pending',
    'get_schema() should return default "pending" for status field'
);

-- Test that a required enum with a default is surfaced as inputMode required …
SELECT is(
    (public.get_schema('orders')::jsonb)->'properties'->'status'->>'inputMode',
    'required',
    'get_schema() should return inputMode "required" for status field'
);

-- … but is NOT in the required array (it has a non-NULL default)
SELECT ok(
    NOT ((public.get_schema('orders')::jsonb)->'required' @> '["status"]'::jsonb),
    'get_schema() required array should NOT contain status field (has default value)'
);

-- Test optional enum (employees.title_of_courtesy): declared values plus the implicit ''
SELECT ok(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->'enum' @> '["Mr.", "Mrs.", "Ms.", "Dr."]'::jsonb,
    'get_schema() optional enum array should contain the declared values'
);

SELECT ok(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->'enum' @> '[""]'::jsonb,
    'get_schema() optional enum array should include the empty string'
);

SELECT is(
    (public.get_schema('employees')::jsonb)->'properties'->'title_of_courtesy'->>'default',
    '',
    'get_schema() should return default empty string for optional enum title_of_courtesy'
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

-- Test created_at has correct input_mode
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

-- Test updated_at has correct input_mode
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'updated_at'->>'inputMode',
    'disabled',
    'get_schema() updated_at should have inputMode disabled'
);

-- =====================================================
-- TEST: contact_name / contact_title field order (35 / 40)
-- =====================================================

-- Test that contact_name field has field_order 35
SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'contact_name'->>'field_order')::INTEGER,
    35,
    'get_schema() should return field_order 35 for contact_name field'
);

-- Test that contact_title field has field_order 40
SELECT is(
    ((public.get_schema('customers')::jsonb)->'properties'->'contact_title'->>'field_order')::INTEGER,
    40,
    'get_schema() should return field_order 40 for contact_title field'
);

-- =====================================================
-- TEST: is_core fields (id, label, created_at, updated_at)
-- =====================================================

-- Test that id field is marked as is_core
SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields WHERE table_name = 'customers' AND field_name = 'id'),
    TRUE,
    'id field should be marked as is_core = TRUE'
);

-- Test that company_name (label) field is marked as is_core
SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields WHERE table_name = 'customers' AND field_name = 'company_name'),
    TRUE,
    'company_name (label) field should be marked as is_core = TRUE'
);

-- Test that created_at field is marked as is_core
SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields WHERE table_name = 'customers' AND field_name = 'created_at'),
    TRUE,
    'created_at field should be marked as is_core = TRUE'
);

-- Test that updated_at field is marked as is_core
SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields WHERE table_name = 'customers' AND field_name = 'updated_at'),
    TRUE,
    'updated_at field should be marked as is_core = TRUE'
);

-- Test that non-core fields (like customer_id) are marked as is_core = FALSE
SELECT is(
    (SELECT (coalesce(ctype, '') <> '') FROM fields WHERE table_name = 'customers' AND field_name = 'customer_id'),
    FALSE,
    'customer_id field should be marked as is_core = FALSE'
);

-- Switch to admin user for mutation tests
select authenticate_as('user3');

-- Test that attempting to delete a core field (created_at) raises an error
SELECT throws_ok(
    'DELETE FROM fields WHERE table_name = ''customers'' AND field_name = ''created_at''',
    'P0001',
    'Cannot delete core system field "created_at". Core fields (ctype id/label/audit/core) cannot be deleted.',
    'Deleting created_at field should raise an exception'
);

-- Test that attempting to delete a core field (id) raises an error
SELECT throws_ok(
    'DELETE FROM fields WHERE table_name = ''customers'' AND field_name = ''id''',
    'P0001',
    'Cannot delete core system field "id". Core fields (ctype id/label/audit/core) cannot be deleted.',
    'Deleting id field should raise an exception'
);

-- Test that attempting to change format of a core field raises an error
SELECT throws_ok(
    'UPDATE fields SET format = ''text'' WHERE table_name = ''customers'' AND field_name = ''created_at''',
    'P0001',
    'Cannot change format of core system field "created_at"',
    'Changing format of created_at field should raise an exception'
);

-- Test that metadata updates to core fields are allowed (title, description)
SELECT lives_ok(
    'UPDATE fields SET title = ''Record ID'', description = ''Unique identifier'' WHERE table_name = ''customers'' AND field_name = ''id''',
    'Updating title and description of core field should succeed'
);

-- =====================================================
-- TEST: Properties ordering by field_order
-- =====================================================

select authenticate_as('user2');

-- Test that properties keys are ordered by field_order value.
-- get_schema() returns JSON (not JSONB), so json_object_keys() yields the keys in emission
-- order. Derived columns (_label / <fk>_label) are interleaved by the generator and have no
-- fields row, so only authored fields are compared.
WITH actual_order AS (
    SELECT array_agg(k::text ORDER BY o) AS ordered_keys
    FROM json_object_keys(public.get_schema('customers')->'properties') WITH ORDINALITY AS t(k, o)
    WHERE k IN (SELECT field_name FROM fields WHERE table_name = 'customers')
),
expected_order AS (
    SELECT array_agg(field_name::text ORDER BY field_order) AS ordered_fields
    FROM fields
    WHERE table_name = 'customers'
)
SELECT is(
    (SELECT ordered_keys FROM actual_order),
    (SELECT ordered_fields FROM expected_order),
    'get_schema() properties keys should be ordered by field_order value (verified via json key order)'
);

-- =====================================================
-- TEST: Verify get_schema() includes ALL table columns for entities table
-- =====================================================

-- Test that ALL fields defined in fields table for 'entities' are present in get_schema output
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'entities'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'entities' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'entities' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('entities')::jsonb->'properties') AS property_name
)
SELECT is(
    (SELECT COUNT(*) FROM expected_fields),
    (SELECT COUNT(*) FROM actual_properties),
    'get_schema(entities) should include all fields from fields metadata - count match'
);

-- Test that there are NO missing fields (expected - actual = 0)
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'entities'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'entities' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'entities' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('entities')::jsonb->'properties') AS property_name
),
missing_fields AS (
    SELECT field_name
    FROM expected_fields
    WHERE field_name NOT IN (SELECT property_name FROM actual_properties)
)
SELECT is(
    (SELECT string_agg(field_name, ', ' ORDER BY field_name) FROM missing_fields),
    NULL,
    'get_schema(entities) should have no missing fields'
);

-- Test that there are NO extra fields (actual - expected = 0)
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'entities'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'entities' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'entities' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('entities')::jsonb->'properties') AS property_name
),
extra_fields AS (
    SELECT property_name
    FROM actual_properties
    WHERE property_name NOT IN (SELECT field_name FROM expected_fields)
)
SELECT is(
    (SELECT string_agg(property_name, ', ' ORDER BY property_name) FROM extra_fields),
    NULL,
    'get_schema(entities) should have no extra fields'
);

-- =====================================================
-- TEST: Verify get_schema() includes ALL field columns for fields table
-- =====================================================

-- Test that ALL fields defined in fields table for 'fields' are present in get_schema output
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'fields'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'fields' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'fields' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('fields')::jsonb->'properties') AS property_name
)
SELECT is(
    (SELECT COUNT(*) FROM expected_fields),
    (SELECT COUNT(*) FROM actual_properties),
    'get_schema(fields) should include all fields from fields metadata - count match'
);

-- Test that there are NO missing fields
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'fields'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'fields' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'fields' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('fields')::jsonb->'properties') AS property_name
),
missing_fields AS (
    SELECT field_name
    FROM expected_fields
    WHERE field_name NOT IN (SELECT property_name FROM actual_properties)
)
SELECT is(
    (SELECT string_agg(field_name, ', ' ORDER BY field_name) FROM missing_fields),
    NULL,
    'get_schema(fields) should have no missing fields'
);

-- Test that there are NO extra fields
WITH expected_fields AS (
    -- authored fields PLUS the derived label columns that get_schema must expose (so a missing
    -- _label / <fk>_label is caught), computed from the same metadata the generator uses
    SELECT field_name FROM fields WHERE table_name = 'fields'
    UNION SELECT '_label'
    UNION SELECT f.field_name || '_label' FROM fields f
      WHERE f.table_name = 'fields' AND f.format IN ('reference','parent') AND f.reference_table <> ''
        AND NOT EXISTS (SELECT 1 FROM fields f2 WHERE f2.table_name = 'fields' AND f2.field_name = f.field_name || '_label')
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('fields')::jsonb->'properties') AS property_name
),
extra_fields AS (
    SELECT property_name
    FROM actual_properties
    WHERE property_name NOT IN (SELECT field_name FROM expected_fields)
)
SELECT is(
    (SELECT string_agg(property_name, ', ' ORDER BY property_name) FROM extra_fields),
    NULL,
    'get_schema(fields) should have no extra fields'
);

-- =====================================================
-- TEST: Verify 'table' object includes ALL columns from entities table
-- =====================================================

-- Test that the 'table' object in get_schema output includes all columns from the entities table
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'entities'
),
actual_table_keys AS (
    SELECT jsonb_object_keys(public.get_schema('fields')::jsonb->'table') AS key_name
),
missing_keys AS (
    SELECT field_name
    FROM expected_fields
    WHERE field_name NOT IN (SELECT key_name FROM actual_table_keys)
)
SELECT is(
    (SELECT string_agg(field_name, ', ' ORDER BY field_name) FROM missing_keys),
    NULL,
    'get_schema() table object should include all columns from entities table'
);

-- =====================================================
-- TEST: Verify all properties have required attributes
-- =====================================================

-- Test that all properties include the field_order attribute
WITH schema_properties AS (
    SELECT
        key AS property_name,
        value AS property_def
    FROM jsonb_each(public.get_schema('fields')::jsonb->'properties')
),
missing_field_order AS (
    SELECT property_name
    FROM schema_properties
    WHERE NOT (property_def ? 'field_order')
)
SELECT is(
    (SELECT string_agg(property_name::text, ', ' ORDER BY property_name) FROM missing_field_order),
    NULL,
    'All properties in get_schema() should include field_order attribute'
);

-- =====================================================
-- TEST: Verify that field properties include ctype, is_core, and searchable attributes
-- =====================================================

-- Test that a field with ctype has it in the schema
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'ctype'),
    'get_schema(customers) id field should include ctype'
);

SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id'->>'ctype'),
    'id',
    'get_schema(customers) id field ctype should be "id"'
);

-- Test that all fields have is_core attribute
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'is_core'),
    'get_schema(customers) id field should include is_core'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'company_name' ? 'is_core'),
    'get_schema(customers) company_name field should include is_core'
);

-- Test that all fields have searchable attribute
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'searchable'),
    'get_schema(customers) id field should include searchable'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'company_name' ? 'searchable'),
    'get_schema(customers) company_name field should include searchable'
);

SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'company_name'->>'searchable'),
    'true',
    'get_schema(customers) company_name field searchable should be true'
);

-- =====================================================
-- TEST: Verify reference fields have reference_table, reference_delete_mode, and NEW reference columns
-- =====================================================

-- Test that reference fields include format property
SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'format'),
    'reference',
    'get_schema(orders) customer_id format should be "reference"'
);

-- Test that customer_id field in orders has reference_table and reference_delete_mode
SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_table'),
    'get_schema(orders) customer_id should include reference_table'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_table'),
    'customers',
    'get_schema(orders) customer_id reference_table should be "customers"'
);

SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_delete_mode'),
    'get_schema(orders) customer_id should include reference_delete_mode'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_delete_mode'),
    'restrict',
    'get_schema(orders) customer_id reference_delete_mode should be "restrict"'
);

-- NEW: Test that customer_id has reference_table_id_column
SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_table_id_column'),
    'get_schema(orders) customer_id should include reference_table_id_column'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_table_id_column'),
    'id',
    'get_schema(orders) customer_id reference_table_id_column should be "id"'
);

-- NEW: Test that customer_id has reference_table_label_column
SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_table_label_column'),
    'get_schema(orders) customer_id should include reference_table_label_column'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_table_label_column'),
    'company_name',
    'get_schema(orders) customer_id reference_table_label_column should be "company_name"'
);

-- NEW: Test that customer_id has reference_table_singular_label
SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_table_singular_label'),
    'get_schema(orders) customer_id should include reference_table_singular_label'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_table_singular_label'),
    'Customer',
    'get_schema(orders) customer_id reference_table_singular_label should be "Customer"'
);

-- NEW: Test that customer_id has reference_table_plural_label
SELECT ok(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id' ? 'reference_table_plural_label'),
    'get_schema(orders) customer_id should include reference_table_plural_label'
);

SELECT is(
    (SELECT public.get_schema('orders')::jsonb->'properties'->'customer_id'->>'reference_table_plural_label'),
    'Customers',
    'get_schema(orders) customer_id reference_table_plural_label should be "Customers"'
);

-- Test that category_id field in products has reference_table and reference_delete_mode
SELECT ok(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id' ? 'reference_table'),
    'get_schema(products) category_id should include reference_table'
);

SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id'->>'reference_table'),
    'categories',
    'get_schema(products) category_id reference_table should be "categories"'
);

-- NEW: Test that category_id has reference_table_id_column
SELECT ok(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id' ? 'reference_table_id_column'),
    'get_schema(products) category_id should include reference_table_id_column'
);

SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id'->>'reference_table_id_column'),
    'id',
    'get_schema(products) category_id reference_table_id_column should be "id"'
);

-- NEW: Test that category_id has reference_table_label_column
SELECT ok(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id' ? 'reference_table_label_column'),
    'get_schema(products) category_id should include reference_table_label_column'
);

SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id'->>'reference_table_label_column'),
    'category_name',
    'get_schema(products) category_id reference_table_label_column should be "category_name"'
);

-- NEW: Test that category_id has reference_table_singular_label
SELECT ok(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id' ? 'reference_table_singular_label'),
    'get_schema(products) category_id should include reference_table_singular_label'
);

SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id'->>'reference_table_singular_label'),
    'Category',
    'get_schema(products) category_id reference_table_singular_label should be "Category"'
);

-- NEW: Test that category_id has reference_table_plural_label
SELECT ok(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id' ? 'reference_table_plural_label'),
    'get_schema(products) category_id should include reference_table_plural_label'
);

SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'category_id'->>'reference_table_plural_label'),
    'Categories',
    'get_schema(products) category_id reference_table_plural_label should be "Categories"'
);

-- =====================================================
-- TEST: Fields without reference_table should have empty strings
-- =====================================================

-- Test that a non-reference field (phone) has no reference_table_* keys
-- Since phone doesn't have format='reference', these properties should not be present at all
SELECT ok(
    NOT ((SELECT public.get_schema('customers')::jsonb->'properties'->'phone' ? 'reference_table_id_column')),
    'get_schema(customers) phone (non-reference field) should NOT include reference_table_id_column'
);

SELECT ok(
    NOT ((SELECT public.get_schema('customers')::jsonb->'properties'->'phone' ? 'reference_table_label_column')),
    'get_schema(customers) phone (non-reference field) should NOT include reference_table_label_column'
);

SELECT ok(
    NOT ((SELECT public.get_schema('customers')::jsonb->'properties'->'phone' ? 'reference_table_singular_label')),
    'get_schema(customers) phone (non-reference field) should NOT include reference_table_singular_label'
);

SELECT ok(
    NOT ((SELECT public.get_schema('customers')::jsonb->'properties'->'phone' ? 'reference_table_plural_label')),
    'get_schema(customers) phone (non-reference field) should NOT include reference_table_plural_label'
);

-- =====================================================
-- TEST: get_schema() children array
-- =====================================================

-- Test that children key exists in get_schema output
SELECT ok(
    (public.get_schema('customers')::jsonb) ? 'children',
    'get_schema(customers) should include children key'
);

-- Test that children is an array
SELECT is(
    jsonb_typeof((public.get_schema('customers')::jsonb)->'children'),
    'array',
    'get_schema(customers) children should be a JSON array'
);

-- Test that children for customers is empty (only format=reference FKs point at customers, no parent)
SELECT is(
    jsonb_array_length((public.get_schema('customers')::jsonb)->'children'),
    0,
    'get_schema(customers) children should be empty'
);

-- Test that order_details.order_id (format=parent) is in children for orders
SELECT ok(
    (public.get_schema('orders')::jsonb)->'children' @> '[{"id": "order_details.order_id"}]'::jsonb,
    'get_schema(orders) children should include order_details.order_id'
);

-- Test children entry for order_details.order_id has correct singular_label
SELECT is(
    (SELECT elem->>'singular_label'
     FROM jsonb_array_elements((public.get_schema('orders')::jsonb)->'children') elem
     WHERE elem->>'id' = 'order_details.order_id'),
    'Order Detail',
    'get_schema(orders) children order_details.order_id should have singular_label "Order Detail"'
);

-- Test children entry for order_details.order_id has correct plural_label
SELECT is(
    (SELECT elem->>'plural_label'
     FROM jsonb_array_elements((public.get_schema('orders')::jsonb)->'children') elem
     WHERE elem->>'id' = 'order_details.order_id'),
    'Order Details',
    'get_schema(orders) children order_details.order_id should have plural_label "Order Details"'
);

-- Test that children key exists in get_schema for users
SELECT ok(
    (public.get_schema('users')::jsonb) ? 'children',
    'get_schema(users) should include children key'
);

-- Test that children for users is an array
SELECT is(
    jsonb_typeof((public.get_schema('users')::jsonb)->'children'),
    'array',
    'get_schema(users) children should be a JSON array'
);

-- Test that children for users has at least 1 item (user_roles.user_id)
SELECT ok(
    jsonb_array_length((public.get_schema('users')::jsonb)->'children') >= 1,
    'get_schema(users) children should contain at least one entry'
);

-- Test that user_roles.user_id is in children for users
SELECT ok(
    (public.get_schema('users')::jsonb)->'children' @> '[{"id": "user_roles.user_id"}]'::jsonb,
    'get_schema(users) children should include user_roles.user_id'
);

-- Test children entry for user_roles.user_id has correct title
SELECT is(
    (SELECT elem->>'title'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'User Id',
    'get_schema(users) children user_roles.user_id should have title "User Id"'
);

-- Test children entry for user_roles.user_id has correct singular_label
SELECT is(
    (SELECT elem->>'singular_label'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'User Role',
    'get_schema(users) children user_roles.user_id should have singular_label "User Role"'
);

-- Test children entry for user_roles.user_id has correct plural_label
SELECT is(
    (SELECT elem->>'plural_label'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'User Roles',
    'get_schema(users) children user_roles.user_id should have plural_label "User Roles"'
);

-- Test children entry for user_roles.user_id has correct id_column
SELECT is(
    (SELECT elem->>'id_column'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'id',
    'get_schema(users) children user_roles.user_id should have id_column "id"'
);

-- Test children entry for user_roles.user_id has correct label_column
SELECT is(
    (SELECT elem->>'label_column'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'id',
    'get_schema(users) children user_roles.user_id should have label_column "id"'
);

-- =====================================================
-- TEST: singular_label_parent / plural_label_parent in properties
-- =====================================================

-- user_roles requires admin access, switch to user3 for these tests
select authenticate_as('user3');

-- Test that user_id property in user_roles includes singular_label_parent
SELECT is(
    (SELECT public.get_schema('user_roles')::jsonb->'properties'->'user_id'->>'singular_label_parent'),
    'Role',
    'get_schema(user_roles) user_id should have singular_label_parent "Role"'
);

-- Test that user_id property in user_roles includes plural_label_parent
SELECT is(
    (SELECT public.get_schema('user_roles')::jsonb->'properties'->'user_id'->>'plural_label_parent'),
    'Roles',
    'get_schema(user_roles) user_id should have plural_label_parent "Roles"'
);

-- Test that role_id property in user_roles includes singular_label_parent
SELECT is(
    (SELECT public.get_schema('user_roles')::jsonb->'properties'->'role_id'->>'singular_label_parent'),
    'User',
    'get_schema(user_roles) role_id should have singular_label_parent "User"'
);

-- Test that a non-parent field does NOT include singular_label_parent
SELECT ok(
    NOT ((SELECT public.get_schema('user_roles')::jsonb->'properties'->'assigned_at' ? 'singular_label_parent')),
    'get_schema(user_roles) assigned_at (non-parent field) should NOT include singular_label_parent'
);

-- =====================================================
-- TEST: singular_label_parent / plural_label_parent in children
-- =====================================================

select authenticate_as('user2');

-- Test children entry for user_roles.user_id has correct singular_label_parent
SELECT is(
    (SELECT elem->>'singular_label_parent'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'Role',
    'get_schema(users) children user_roles.user_id should have singular_label_parent "Role"'
);

-- Test children entry for user_roles.user_id has correct plural_label_parent
SELECT is(
    (SELECT elem->>'plural_label_parent'
     FROM jsonb_array_elements((public.get_schema('users')::jsonb)->'children') elem
     WHERE elem->>'id' = 'user_roles.user_id'),
    'Roles',
    'get_schema(users) children user_roles.user_id should have plural_label_parent "Roles"'
);

-- =====================================================
-- TEST: cube_type included in field properties
-- =====================================================

-- Test that a field includes cube_type in its schema properties
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'cube_type'),
    'get_schema(customers) id field should include cube_type'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'company_name' ? 'cube_type'),
    'get_schema(customers) company_name field should include cube_type'
);

-- Test cube_type default value is "auto"
SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id'->>'cube_type'),
    'auto',
    'get_schema(customers) id field cube_type should default to "auto"'
);

-- Test an explicit cube_type is surfaced (products.units_in_stock is a measure)
SELECT is(
    (SELECT public.get_schema('products')::jsonb->'properties'->'units_in_stock'->>'cube_type'),
    'measure',
    'get_schema(products) units_in_stock field cube_type should be "measure"'
);

-- =====================================================
-- TEST: cube_mode included in table object
-- =====================================================

-- Test that the table object includes cube_mode
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'table' ? 'cube_mode'),
    'get_schema(customers) table object should include cube_mode'
);

-- Test cube_mode default value is "auto"
SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'table'->>'cube_mode'),
    'auto',
    'get_schema(customers) table object cube_mode should default to "auto"'
);

SELECT * FROM finish();
ROLLBACK;
