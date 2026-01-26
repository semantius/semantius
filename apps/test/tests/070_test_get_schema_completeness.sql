-- Test that get_schema() includes all fields from tables and fields metadata
BEGIN;

SELECT plan(21);

select authenticate_as('user1');

-- =====================================================
-- TEST: Verify get_schema() includes ALL table columns for tables table
-- =====================================================

-- Test that ALL fields defined in fields table for 'tables' are present in get_schema output
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'tables'
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('tables')::jsonb->'properties') AS property_name
)
SELECT is(
    (SELECT COUNT(*) FROM expected_fields),
    (SELECT COUNT(*) FROM actual_properties),
    'get_schema(tables) should include all fields from fields metadata - count match'
);

-- Test that there are NO missing fields (expected - actual = 0)
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'tables'
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('tables')::jsonb->'properties') AS property_name
),
missing_fields AS (
    SELECT field_name 
    FROM expected_fields 
    WHERE field_name NOT IN (SELECT property_name FROM actual_properties)
)
SELECT is(
    (SELECT string_agg(field_name, ', ' ORDER BY field_name) FROM missing_fields),
    NULL,
    'get_schema(tables) should have no missing fields'
);

-- Test that there are NO extra fields (actual - expected = 0)
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'tables'
),
actual_properties AS (
    SELECT jsonb_object_keys(public.get_schema('tables')::jsonb->'properties') AS property_name
),
extra_fields AS (
    SELECT property_name 
    FROM actual_properties 
    WHERE property_name NOT IN (SELECT field_name FROM expected_fields)
)
SELECT is(
    (SELECT string_agg(property_name, ', ' ORDER BY property_name) FROM extra_fields),
    NULL,
    'get_schema(tables) should have no extra fields'
);

-- =====================================================
-- TEST: Verify get_schema() includes ALL field columns for fields table
-- =====================================================

-- Test that ALL fields defined in fields table for 'fields' are present in get_schema output
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'fields'
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
    SELECT field_name
    FROM fields
    WHERE table_name = 'fields'
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
    SELECT field_name
    FROM fields
    WHERE table_name = 'fields'
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
-- TEST: Verify 'table' object includes ALL columns from tables table
-- =====================================================

-- Test that the 'table' object in get_schema output includes all columns from the tables table
WITH expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'tables'
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
    'get_schema() table object should include all columns from tables table'
);

-- =====================================================
-- TEST: Verify all properties have required attributes
-- =====================================================

-- Test that all properties include the fieldOrder attribute
WITH schema_properties AS (
    SELECT 
        key AS property_name,
        value AS property_def
    FROM jsonb_each(public.get_schema('fields')::jsonb->'properties')
),
missing_field_order AS (
    SELECT property_name
    FROM schema_properties
    WHERE NOT (property_def ? 'fieldOrder')
)
SELECT is(
    (SELECT string_agg(property_name::text, ', ' ORDER BY property_name) FROM missing_field_order),
    NULL,
    'All properties in get_schema() should include fieldOrder attribute'
);

-- =====================================================
-- TEST: Verify that field properties include ctype, isCore, and searchable attributes
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

-- Test that all fields have isCore attribute
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'isCore'),
    'get_schema(customers) id field should include isCore'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'customer_name' ? 'isCore'),
    'get_schema(customers) customer_name field should include isCore'
);

-- Test that all fields have searchable attribute
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'id' ? 'searchable'),
    'get_schema(customers) id field should include searchable'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'customer_name' ? 'searchable'),
    'get_schema(customers) customer_name field should include searchable'
);

SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'customer_name'->>'searchable'),
    'true',
    'get_schema(customers) customer_name field searchable should be true'
);

-- =====================================================
-- TEST: Verify reference fields have referenceTable and referenceDeleteMode
-- =====================================================

-- Test that region_id field in customers has referenceTable and referenceDeleteMode
SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'region_id' ? 'referenceTable'),
    'get_schema(customers) region_id should include referenceTable'
);

SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'region_id'->>'referenceTable'),
    'regions',
    'get_schema(customers) region_id referenceTable should be "regions"'
);

SELECT ok(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'region_id' ? 'referenceDeleteMode'),
    'get_schema(customers) region_id should include referenceDeleteMode'
);

SELECT is(
    (SELECT public.get_schema('customers')::jsonb->'properties'->'region_id'->>'referenceDeleteMode'),
    'restrict',
    'get_schema(customers) region_id referenceDeleteMode should be "restrict"'
);

-- Test that department_id field in employees has referenceTable and referenceDeleteMode
SELECT ok(
    (SELECT public.get_schema('employees')::jsonb->'properties'->'department_id' ? 'referenceTable'),
    'get_schema(employees) department_id should include referenceTable'
);

SELECT is(
    (SELECT public.get_schema('employees')::jsonb->'properties'->'department_id'->>'referenceTable'),
    'departments',
    'get_schema(employees) department_id referenceTable should be "departments"'
);

SELECT * FROM finish();
ROLLBACK;
