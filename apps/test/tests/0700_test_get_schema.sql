-- public.get_schema() and its multi-table wrapper public.get_schemas().
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. get_schema()
--   2. get_schemas()
--   3. get_schema of is_a and has_a entities
--   4. get_schema_children()
--   5. The schema functions follow the catalog's visibility rule
--   6. An entity the caller may not see answers as a missing one
--   7. A reference to an entity the caller may not see
BEGIN;

SELECT plan(193);

-- =====================================================
-- PART 1: get_schema()
-- =====================================================
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
-- Module/role/permission ids are never hard-coded (the nwind module's id is whatever the sequence handed out).

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
    ((public.get_schema('customers')::jsonb)->'table'->>'module_id')::BIGINT,
    (SELECT nwind_module_id FROM sch_ids),
    'get_schema() table object should contain module_id of the nwind module'
);

-- Test table.module_slug — denormalized from modules so a consumer holding a schema can call
-- get_module_cubes(), which matches on the slug and not on module_id.
SELECT is(
    (public.get_schema('customers')::jsonb)->'table'->>'module_slug',
    'nwind',
    'get_schema() table object should contain the module_slug of the nwind module'
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

-- Test that get_schema() raises the "not found" error of a missing table for
-- webhook_receivers (viewed and edited with admin), which user1 does not see
SELECT throws_ok(
    'SELECT public.get_schema(''webhook_receivers'')',
    '42P01',
    'Table "webhook_receivers" not found in entities',
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

-- Test format field is present for plain text fields (format: text is returned too)
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
    'get_schema() should map the int64 id format to integer type'
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

SELECT is(
    (public.get_schema('sch_probe')::jsonb)->'properties'->'ratio'->>'format',
    'double',
    'get_schema() should include format double for the double field'
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

-- Test that the int64 format appears in output alongside type: integer
SELECT is(
    (public.get_schema('customers')::jsonb)->'properties'->'id'->>'format',
    'int64',
    'get_schema() should include format int64 for the int64 id field'
);

SELECT is(
    (public.get_schema('products')::jsonb)->'properties'->'units_in_stock'->>'format',
    'int32',
    'get_schema() should include format int32 for units_in_stock'
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
    '90217',
    'Cannot delete core system field ${field_name}. Core fields (ctype id/label/audit/core) cannot be deleted.',
    'Deleting created_at field should raise an exception'
);

-- Test that attempting to delete a core field (id) raises an error
SELECT throws_ok(
    'DELETE FROM fields WHERE table_name = ''customers'' AND field_name = ''id''',
    '90217',
    'Cannot delete core system field ${field_name}. Core fields (ctype id/label/audit/core) cannot be deleted.',
    'Deleting id field should raise an exception'
);

-- Test that attempting to change format of a core field raises an error
SELECT throws_ok(
    'UPDATE fields SET format = ''text'' WHERE table_name = ''customers'' AND field_name = ''created_at''',
    '90219',
    'Cannot change format of core system field ${field_name}',
    'Changing format of created_at field should raise an exception'
);

-- Test that metadata updates to core fields are allowed (title, description)
SELECT lives_ok(
    'UPDATE fields SET title = ''Record ID'', description = ''Unique identifier'' WHERE table_name = ''customers'' AND field_name = ''id''',
    'Updating title and description of core field should succeed'
);

-- =====================================================
-- TEST: A form seeded from get_schema('modules') saves
-- =====================================================
-- A client fills every field it does not show from the schema default and
-- sends it, so each default has to be a value the column accepts.

SELECT is(
    (public.get_schema('modules')::jsonb)->'properties'->'access_scope'->>'default',
    'custom',
    'modules.access_scope defaults to custom, the column default, not the empty string its CHECK rejects'
);

SELECT is(
    (public.get_schema('modules')::jsonb)->'properties'->'access_scope'->>'inputMode',
    'required',
    'modules.access_scope is required, so a form cannot clear it to the empty string'
);

SELECT ok(
    NOT ((public.get_schema('modules')::jsonb)->'properties'->'manage_permission' ? 'default'),
    'a reference to a text-keyed entity with no default gets no schema default (the empty string fails its foreign key)'
);

SELECT is(
    (public.get_schema('modules')::jsonb)->'properties'->'view_permission'->>'default',
    'user:read',
    'a reference to a text-keyed entity keeps an explicit default'
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

-- user_roles is viewable with admin only, and a child is listed for a caller
-- who may view it, so its place among the children of users is read as an
-- administrator.
select authenticate_as('user3');

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
    (SELECT title FROM fields WHERE table_name = 'user_roles' AND field_name = 'user_id'),
    'get_schema(users) children user_roles.user_id title should match its DD field title'
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

select authenticate_as('user2');

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

-- =====================================================
-- PART 2: get_schemas()
-- =====================================================
-- Test public.get_schemas() (multi-table wrapper around get_schema()).
--
-- Caller is user2 (nwind:view) reading the persisted nwind entity 'customers';
-- user1 cannot read nwind. Per-schema structure ($schema, title, properties,
-- table, required, children) is covered by part 1; here the
-- single-table result is pinned to be identical to get_schema() instead.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST: get_schemas() returns correct data
-- =====================================================
select authenticate_as('user2');

-- Test that get_schemas() returns a JSON value for a single table
SELECT ok(
    public.get_schemas('customers') IS NOT NULL,
    'get_schemas() should return a non-null JSON value'
);

-- Test that get_schemas() returns an array type
SELECT ok(
    json_typeof(public.get_schemas('customers')) = 'array',
    'get_schemas() should return a JSON array'
);

-- Test that a single-table call returns an array with one element
SELECT is(
    json_array_length(public.get_schemas('customers')),
    1,
    'get_schemas() with one table name should return an array with one element'
);

-- Test empty string returns empty array (blank entries are always skipped)
SELECT is(
    json_array_length(public.get_schemas('')),
    0,
    'get_schemas() with empty string should return empty array'
);

-- Test that get_schemas() output matches get_schema() for the same table
SELECT is(
    (public.get_schemas('customers')::jsonb)->0,
    public.get_schema('customers')::jsonb,
    'get_schemas() single-table result should match get_schema() output exactly'
);

-- Blank entries (a leading, repeated or trailing comma, or a lone space) are
-- skipped and never looked up as a table named ''
SELECT is(
    json_array_length(public.get_schemas(' , ')),
    0,
    'get_schemas() with only blank entries should return an empty array'
);

SELECT is(
    (public.get_schemas(',customers, ,')::jsonb),
    jsonb_build_array(public.get_schema('customers')::jsonb),
    'get_schemas() should skip blank entries around a table name'
);

-- =====================================================
-- TEST: get_schemas() raises errors for missing/inaccessible tables
-- =====================================================

-- Test that a non-existent table raises an error
SELECT throws_ok(
    'SELECT public.get_schemas(''nonexistent_table_xyz'')',
    '42P01',
    'Table "nonexistent_table_xyz" not found in entities',
    'get_schemas() should raise an error for a non-existent table'
);

-- Test that a non-existent table in a mixed list still raises an error
SELECT throws_ok(
    'SELECT public.get_schemas(''customers, nonexistent_table_xyz'')',
    '42P01',
    'Table "nonexistent_table_xyz" not found in entities',
    'get_schemas() should raise an error even when only one table in the list does not exist'
);

-- Test that a table the user cannot access raises the error of a missing one
-- (user2 does not have admin permission, so webhook_receivers is inaccessible)
SELECT throws_ok(
    'SELECT public.get_schemas(''customers, webhook_receivers'')',
    '42P01',
    'Table "webhook_receivers" not found in entities',
    'get_schemas() should raise an error when the user lacks view permission for any table in the list'
);

-- =====================================================
-- PART 3: get_schema of is_a and has_a entities
-- =====================================================
-- The schema of a derived entity describes its whole record: the root's
-- fields first, then each level's, then its own, the inherited ones marked
-- with the entity that owns them. A has_a base lists its extensions, those the
-- caller may view; the view permission of every level gates each schema.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix)
VALUES ('gs_parties', 'Party', 'Parties', 1, 'typeid', 'gspty');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('gs_parties', 'city', 'City', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity)
VALUES ('gs_orgs', 'Organization', 'Organizations', 1, 'is_a', 'gsorg', 'gs_parties');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('gs_orgs', 'vat', 'VAT', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_refentity, view_permission)
VALUES ('gs_clients', 'Client', 'Clients', 1, 'has_a', 'gs_parties', 'admin'),
       ('gs_vendors', 'Vendor', 'Vendors', 1, 'has_a', 'gs_parties', 'public:read');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('gs_clients', 'credit', 'Credit', 'int32', 30),
       ('gs_vendors', 'rating', 'Rating', 'int32', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id)
VALUES ('gs_notes', 'Note', 'Notes', 1);
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('gs_notes', 'org_id', 'Organization', 'reference', 'gs_orgs', 'restrict', 30);

SELECT is(
    (SELECT string_agg(k, ', ' ORDER BY n)
       FROM json_object_keys(public.get_schema('gs_orgs') -> 'properties') WITH ORDINALITY AS t(k, n)),
    'id, label, _label, city, vat, created_at, updated_at',
    'family schema: the key, the root''s fields, the own fields, then the audit fields');

SELECT is(
    (SELECT string_agg(k || '=' || coalesce(v ->> 'inherited_from', '-'), ', ' ORDER BY k)
       FROM jsonb_each((public.get_schema('gs_orgs')::jsonb) -> 'properties') AS t(k, v)
      WHERE k IN ('id', 'label', 'city', 'vat')),
    'city=gs_parties, id=-, label=gs_parties, vat=-',
    'family schema: an inherited field names the entity that owns it');

SELECT ok(
    (public.get_schema('gs_orgs')::jsonb) #>> '{properties,id,pattern}' IS NOT NULL
    AND (public.get_schema('gs_vendors')::jsonb) #>> '{properties,id,pattern}' IS NOT NULL
    AND (public.get_schema('gs_notes')::jsonb) #>> '{properties,org_id,pattern}' IS NOT NULL,
    'family schema: is_a and has_a keys, and references to them, carry the TypeID pattern');

SELECT is(
    (public.get_schema('gs_orgs')::jsonb) #>> '{table,id_refentity}',
    'gs_parties',
    'family schema: the table object names the base');

SELECT is(
    (SELECT string_agg((e ->> 'table') || ':' || (SELECT string_agg(k, '/') FROM jsonb_object_keys(e -> 'properties') k),
                       ', ' ORDER BY e ->> 'table')
       FROM jsonb_array_elements((public.get_schema('gs_parties')::jsonb) -> 'extensions') e),
    'gs_clients:credit/created_at/updated_at, gs_vendors:rating/created_at/updated_at',
    'family schema: a has_a base lists its extensions with their own fields');

SELECT ok(
    NOT ((public.get_schema('gs_orgs')::jsonb) ? 'extensions')
    AND NOT ((public.get_schema('gs_notes')::jsonb) ? 'extensions'),
    'family schema: an entity without has_a extensions gets no extensions key');

SELECT authenticate_as('user1');
SELECT is(
    (SELECT string_agg(e ->> 'table', ', ')
       FROM jsonb_array_elements((public.get_schema('gs_parties')::jsonb) -> 'extensions') e),
    'gs_vendors',
    'family schema: the extensions list holds only those the caller may view');

SELECT throws_ok($$ SELECT public.get_schema('gs_clients') $$,
    '42P01', NULL,
    'family schema: an extension the caller may not view is not found');

SELECT authenticate_as('user3');
UPDATE entities SET view_permission = 'admin' WHERE table_name = 'gs_parties';
SELECT authenticate_as('user1');
SELECT throws_ok($$ SELECT public.get_schema('gs_vendors') $$,
    '42P01', NULL,
    'family schema: the view permission of every level gates the schema');

-- =====================================================
-- PART 4: get_schema_children()
-- =====================================================
-- The children of a table are the fields of other tables that point at it with
-- format 'parent'. They are part of what get_schema() shows about the parent,
-- and the function is callable on its own. The caller sees a child only when
-- the caller may see the child's table (its view_permission): a child the
-- caller may not view is not described to them, and a parent the caller may
-- not view lists no children.
--
-- Fixtures: the persisted orders (view nwind:view) with its child order_details,
-- and an ephemeral parent gsc_parent (public:read) with two children, gsc_open
-- (public:read) and gsc_closed (admin). user2 holds nwind:view, user1 holds
-- neither it nor admin.
--
-- pg_temp.child_ids reports the child field ids the function returns, or the
-- SQLSTATE it raised, so a refusal shows up in the assertion and does not abort
-- the file.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.child_ids(p_table TEXT) RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(
        (SELECT string_agg(c ->> 'id', ', ' ORDER BY c ->> 'id')
           FROM json_array_elements(public.get_schema_children(p_table)) AS c),
        '');
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission)
VALUES ('gsc_parent', 'Child Probe Parent', 'Child Probe Parents', 1, 'public:read'),
       ('gsc_open',   'Open Child',         'Open Children',       1, 'public:read'),
       ('gsc_closed', 'Closed Child',       'Closed Children',     1, 'admin');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('gsc_open',   'parent_id', 'Parent', 'parent', 'gsc_parent', 'cascade', 30),
       ('gsc_closed', 'parent_id', 'Parent', 'parent', 'gsc_parent', 'cascade', 30);

SELECT is(pg_temp.child_ids('gsc_parent'), 'gsc_closed.parent_id, gsc_open.parent_id',
    'get_schema_children: an administrator sees every child of the parent');

SELECT authenticate_as('user2');
SELECT is(pg_temp.child_ids('orders'), 'order_details.order_id',
    'get_schema_children: a caller who may view the parent and the child sees the child');

SELECT is(pg_temp.child_ids('gsc_parent'), 'gsc_open.parent_id',
    'get_schema_children: a child the caller may not view is not listed');

SELECT authenticate_as('user1');
SELECT is(pg_temp.child_ids('gsc_parent'), 'gsc_open.parent_id',
    'get_schema_children: a plain user sees only the child it may view');

SELECT is(pg_temp.child_ids('orders'), '',
    'get_schema_children: a caller who may not view the parent or the child sees no child');

SELECT is(pg_temp.child_ids('no_such_table'), '',
    'get_schema_children: a table that is nobody''s parent has no children');

-- No claims at all: the authentication gate refuses before anything is read.
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_external_id', '', true);
SET ROLE semantius_user;
SELECT is(pg_temp.child_ids('orders'), 'raised 42501',
    'get_schema_children: a session without claims is refused');

-- =====================================================
-- PART 5: The schema functions follow the catalog's visibility rule
-- =====================================================
-- get_schema, get_schemas, build_schema_for_table and get_schema_children
-- describe an entity to exactly the users who see its rows in entities and
-- fields (0300_test_rls.sql): a holder of its view permission, its edit
-- permission or admin, and for an is_a or has_a entity on every level of its
-- chain. The extensions a has_a base lists, and the children a parent lists,
-- follow the same rule.
--
-- Fixtures, created as user3:
--   permissions  gsv:view, gsv:edit, and gsv:base and gsv:base_edit for the base
--   entities     gsv_guarded      view gsv:view, edit gsv:edit
--                gsv_line         view gsv:view, edit gsv:edit, parent field guarded_id to gsv_guarded
--                gsv_root         typeid base, view gsv:base, edit gsv:base_edit
--                gsv_org          is_a gsv_root,  view gsv:view, edit gsv:edit
--                gsv_org_line     view gsv:view, edit gsv:edit, parent field org_id to gsv_org
--                gsv_party        typeid base, view public:read, edit admin
--                gsv_party_addon  has_a gsv_party, view gsv:view, edit gsv:edit
--   users        gsv_viewer (gsv:view), gsv_editor (gsv:edit), gsv_base_editor
--                (gsv:edit and gsv:base_edit), gsv_admin (admin), each with the
--                User role every user gets
-- user1 holds none of the gsv permissions. user3's Administrator role holds
-- every one of them, so the holder of admin without them is gsv_admin.
--
-- pg_temp.gsv_tables runs a statement that returns a schema or an array of
-- them and reports the tables they describe, pg_temp.gsv_extensions reports
-- the extensions get_schema lists for a has_a base, and pg_temp.child_ids
-- (PART 4) the children; each reports a refusal by its SQLSTATE, so it shows
-- up in the assertion and does not abort the file.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.gsv_tables(p_sql TEXT) RETURNS TEXT AS $$
DECLARE
    v_result JSON;
BEGIN
    EXECUTE p_sql INTO v_result;
    IF json_typeof(v_result) = 'array' THEN
        RETURN COALESCE((SELECT string_agg(s #>> '{table,table_name}', ', ' ORDER BY n)
                           FROM json_array_elements(v_result) WITH ORDINALITY AS t(s, n)), '');
    END IF;
    RETURN v_result #>> '{table,table_name}';
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.gsv_extensions(p_table TEXT) RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(
        (SELECT string_agg(e ->> 'table', ', ' ORDER BY e ->> 'table' COLLATE "C")
           FROM json_array_elements(public.get_schema(p_table) -> 'extensions') AS e),
        '');
EXCEPTION WHEN OTHERS THEN
    RETURN 'raised ' || SQLSTATE;
END;
$$ LANGUAGE plpgsql;

SELECT authenticate_as('user3');

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('gsv:view',      'Views the guarded schema probes', 1),
    ('gsv:edit',      'Edits the guarded schema probes', 1),
    ('gsv:base',      'Views the hidden schema base',    1),
    ('gsv:base_edit', 'Edits the hidden schema base',    1);

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('gsv_guarded', 'Guarded Schema Probe', 'Guarded Schema Probes', 1, 'gsv:view', 'gsv:edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      view_permission, edit_permission)
VALUES ('gsv_root',  'Root Schema Probe',  'Root Schema Probes',  1, 'typeid', 'gsvrt',  'gsv:base',    'gsv:base_edit'),
       ('gsv_party', 'Party Schema Probe', 'Party Schema Probes', 1, 'typeid', 'gsvpty', 'public:read', 'admin');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      id_refentity, view_permission, edit_permission)
VALUES ('gsv_org', 'Organization Schema Probe', 'Organization Schema Probes', 1, 'is_a', 'gsvorg',
        'gsv_root', 'gsv:view', 'gsv:edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type,
                      id_refentity, view_permission, edit_permission)
VALUES ('gsv_party_addon', 'Party Extension Schema Probe', 'Party Extension Schema Probes', 1, 'has_a',
        'gsv_party', 'gsv:view', 'gsv:edit');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('gsv_line',     'Line Schema Probe',              'Line Schema Probes',              1, 'gsv:view', 'gsv:edit'),
       ('gsv_org_line', 'Organization Line Schema Probe', 'Organization Line Schema Probes', 1, 'gsv:view', 'gsv:edit');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order) VALUES
    ('gsv_line',     'guarded_id', 'Guarded',      'parent', 'gsv_guarded', 'cascade',  30),
    ('gsv_org_line', 'org_id',     'Organization', 'parent', 'gsv_org',     'restrict', 30);
INSERT INTO fields (table_name, field_name, title, format, field_order) VALUES
    ('gsv_party_addon', 'rating', 'Rating', 'int32', 30);

INSERT INTO users (external_id, email, display_name) VALUES
    ('gsv_viewer',      'gsv_viewer@test.com',      'Schema Viewer'),
    ('gsv_editor',      'gsv_editor@test.com',      'Schema Editor'),
    ('gsv_base_editor', 'gsv_base_editor@test.com', 'Schema Base Editor'),
    ('gsv_admin',       'gsv_admin@test.com',       'Schema Administrator');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, g.permission_name
  FROM (VALUES ('gsv_viewer',      'gsv:view'),
               ('gsv_editor',      'gsv:edit'),
               ('gsv_base_editor', 'gsv:edit'),
               ('gsv_base_editor', 'gsv:base_edit'),
               ('gsv_admin',       'admin')) AS g(external_id, permission_name)
  JOIN users AS u ON u.external_id = g.external_id;

-- ---------------------------------------------------------------------------
-- The view permission of the entity, not of its base
-- ---------------------------------------------------------------------------
SELECT authenticate_as('gsv_viewer');

SELECT is(pg_temp.child_ids('gsv_org'), '',
    'schema visibility, is_a parent, own view permission, base hidden: get_schema_children lists no child');

-- ---------------------------------------------------------------------------
-- The edit permission alone
-- ---------------------------------------------------------------------------
SELECT authenticate_as('gsv_editor');

SELECT is(pg_temp.gsv_tables($$SELECT public.get_schema('gsv_guarded')$$), 'gsv_guarded',
    'schema visibility, edit permission only: get_schema returns the schema');
SELECT is(pg_temp.gsv_tables($$SELECT public.get_schemas('gsv_guarded')$$), 'gsv_guarded',
    'schema visibility, edit permission only: get_schemas returns the schema');
SELECT is(pg_temp.gsv_tables($$SELECT public.build_schema_for_table('gsv_guarded')$$), 'gsv_guarded',
    'schema visibility, edit permission only: build_schema_for_table returns the schema');
SELECT is(pg_temp.child_ids('gsv_guarded'), 'gsv_line.guarded_id',
    'schema visibility, edit permission only: get_schema_children lists the child');
SELECT is(pg_temp.gsv_extensions('gsv_party'), 'gsv_party_addon',
    'schema visibility, edit permission only: a has_a base lists the extension');

-- ---------------------------------------------------------------------------
-- The edit permission of every level
-- ---------------------------------------------------------------------------
SELECT authenticate_as('gsv_base_editor');

SELECT is(pg_temp.gsv_tables($$SELECT public.get_schema('gsv_org')$$), 'gsv_org',
    'schema visibility, is_a entity, edit permission of every level: get_schema returns the schema');

-- ---------------------------------------------------------------------------
-- admin as a direct grant
-- ---------------------------------------------------------------------------
SELECT authenticate_as('gsv_admin');

SELECT is(pg_temp.gsv_tables($$SELECT public.get_schema('gsv_org')$$), 'gsv_org',
    'schema visibility, admin without the permissions of any level: get_schema returns the schema');

-- =====================================================
-- PART 6: An entity the caller may not see answers as a missing one
-- =====================================================
-- A caller who may not see an entity gets exactly the answer it gets for an
-- entity that does not exist, so the answer does not tell it that the entity
-- exists: every field of the error is the same, the table name aside. A
-- holder of admin sees every entity, so it tells a missing entity from an
-- existing one by the answer itself: "not found in entities" for the first,
-- the schema (PART 5) for the second.
--
-- pg_temp.gsv_error fills the table name into a statement, runs it, and
-- returns every field of the error it raises with the name replaced by
-- <table>. The context is one of the fields: a client connected directly, as
-- an OAuth bearer session is, receives it with the error, and its line number
-- tells two raising statements apart.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.gsv_error(p_sql TEXT, p_table TEXT) RETURNS JSONB AS $$
DECLARE
    v_sqlstate   TEXT;
    v_message    TEXT;
    v_detail     TEXT;
    v_hint       TEXT;
    v_context    TEXT;
    v_schema     TEXT;
    v_table      TEXT;
    v_column     TEXT;
    v_datatype   TEXT;
    v_constraint TEXT;
BEGIN
    EXECUTE format(p_sql, p_table);
    RETURN jsonb_build_object('raised', FALSE);
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        v_sqlstate   = RETURNED_SQLSTATE,
        v_message    = MESSAGE_TEXT,
        v_detail     = PG_EXCEPTION_DETAIL,
        v_hint       = PG_EXCEPTION_HINT,
        v_context    = PG_EXCEPTION_CONTEXT,
        v_schema     = SCHEMA_NAME,
        v_table      = TABLE_NAME,
        v_column     = COLUMN_NAME,
        v_datatype   = PG_DATATYPE_NAME,
        v_constraint = CONSTRAINT_NAME;
    RETURN replace(
        jsonb_build_object('sqlstate', v_sqlstate, 'message', v_message, 'detail', v_detail,
                           'hint', v_hint, 'context', v_context, 'schema', v_schema,
                           'table', v_table, 'column', v_column, 'datatype', v_datatype,
                           'constraint', v_constraint)::text,
        p_table, '<table>')::jsonb;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Neither permission
-- ---------------------------------------------------------------------------
SELECT authenticate_as('user1');

SELECT is(
    (SELECT (e ->> 'sqlstate') || ' ' || (e ->> 'message')
       FROM pg_temp.gsv_error('SELECT public.get_schema(%L)', 'gsv_missing') AS e),
    '42P01 Table "<table>" not found in entities',
    'schema answer, missing entity: get_schema raises undefined_table, not found in entities');
SELECT is(
    pg_temp.gsv_error('SELECT public.get_schema(%L)', 'gsv_guarded'),
    pg_temp.gsv_error('SELECT public.get_schema(%L)', 'gsv_missing'),
    'schema answer, neither permission: get_schema raises exactly the error of a missing entity');
SELECT is(
    pg_temp.gsv_error('SELECT public.get_schemas(%L)', 'gsv_guarded'),
    pg_temp.gsv_error('SELECT public.get_schemas(%L)', 'gsv_missing'),
    'schema answer, neither permission: get_schemas raises exactly the error of a missing entity');
SELECT is(
    pg_temp.gsv_error('SELECT public.build_schema_for_table(%L)', 'gsv_guarded'),
    pg_temp.gsv_error('SELECT public.build_schema_for_table(%L)', 'gsv_missing'),
    'schema answer, neither permission: build_schema_for_table raises exactly the error of a missing entity');

-- =====================================================
-- PART 7: A reference to an entity the caller may not see
-- =====================================================
-- A field that references an entity the caller may not see keeps the
-- target's table name, as its fields row does, and nothing more:
-- get_schema adds no label, no key column and no <fk>_label text taken from
-- the hidden target's entities row. The JSON type and the TypeID pattern
-- describe the field's own column, so they stay. A caller who may see the
-- target gets them.
--
-- Fixture, created as user3: gsv_pointer, viewed with public:read, with the
-- reference fields target_id to gsv_guarded and org_id to gsv_org (PART 5),
-- whose key is a TypeID. user1 may see neither target; gsv_viewer may see
-- gsv_guarded. gsv_targets keeps, as stored, what a reference property takes
-- from that target.
--
-- pg_temp.gsv_schema returns the schema of a table, or the SQLSTATE of the
-- refusal; pg_temp.gsv_from_target returns what a reference property holds of
-- its target's entities row: its two labels and its two key columns, the
-- empty ones left out.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE FUNCTION pg_temp.gsv_schema(p_table TEXT) RETURNS JSONB AS $$
BEGIN
    RETURN public.get_schema(p_table)::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('raised', SQLSTATE);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.gsv_from_target(p_property JSONB) RETURNS TEXT AS $$
    SELECT concat_ws(' | ',
        NULLIF(p_property ->> 'reference_table_singular_label', ''),
        NULLIF(p_property ->> 'reference_table_plural_label', ''),
        NULLIF(p_property ->> 'reference_table_id_column', ''),
        NULLIF(p_property ->> 'reference_table_label_column', ''));
$$ LANGUAGE sql;

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('gsv_pointer', 'Pointer Schema Probe', 'Pointer Schema Probes', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order) VALUES
    ('gsv_pointer', 'target_id', 'Target',       'reference', 'gsv_guarded', 'restrict', 30),
    ('gsv_pointer', 'org_id',    'Organization', 'reference', 'gsv_org',     'restrict', 40);

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TEMP TABLE gsv_targets AS
SELECT table_name,
       concat_ws(' | ', NULLIF(singular_label, ''), NULLIF(plural_label, ''),
                 NULLIF(id_column, ''), NULLIF(label_column, '')) AS from_target
  FROM entities
 WHERE table_name = 'gsv_guarded';
GRANT SELECT ON gsv_targets TO semantius_user;

-- ---------------------------------------------------------------------------
-- Neither target visible
-- ---------------------------------------------------------------------------
SELECT authenticate_as('user1');

SELECT is(pg_temp.gsv_schema('gsv_pointer') #>> '{properties,target_id,reference_table}', 'gsv_guarded',
    'schema reference, hidden target: the property keeps the target''s table name');
SELECT is(pg_temp.gsv_from_target(pg_temp.gsv_schema('gsv_pointer') #> '{properties,target_id}'), '',
    'schema reference, hidden target: the property holds no label and no key column of the target');
SELECT unalike(COALESCE(pg_temp.gsv_schema('gsv_pointer') #>> '{properties,target_id_label,description}', ''),
    '%Guarded Schema Probe%',
    'schema reference, hidden target: the <fk>_label property does not describe the target by its label');
SELECT is(
    (SELECT jsonb_build_object('type', p -> 'type', 'pattern', p -> 'pattern')
       FROM (SELECT pg_temp.gsv_schema('gsv_pointer') #> '{properties,org_id}' AS p) AS s),
    jsonb_build_object('type', 'string',
                       'pattern', '^([a-z]([a-z_]{0,61}[a-z])?_)?[0-7][0123456789abcdefghjkmnpqrstvwxyz]{25}$'),
    'schema reference, hidden target: the property keeps the JSON type and the TypeID pattern of its own column');

-- ---------------------------------------------------------------------------
-- A visible target
-- ---------------------------------------------------------------------------
SELECT authenticate_as('gsv_viewer');

SELECT is(pg_temp.gsv_from_target(pg_temp.gsv_schema('gsv_pointer') #> '{properties,target_id}'),
    (SELECT from_target FROM gsv_targets WHERE table_name = 'gsv_guarded'),
    'schema reference, visible target: the property holds the target''s labels and key columns');
SELECT alike(COALESCE(pg_temp.gsv_schema('gsv_pointer') #>> '{properties,target_id_label,description}', ''),
    '%Guarded Schema Probe%',
    'schema reference, visible target: the <fk>_label property describes the target by its label');

SELECT * FROM finish();
ROLLBACK;
