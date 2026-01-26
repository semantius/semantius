-- Test that get_schema() includes all fields from tables and fields metadata
BEGIN;

SELECT plan(26);

select authenticate_as('user1');

-- =====================================================
-- TEST: Verify get_schema() includes ALL table columns for tables table
-- =====================================================

-- Get the schema for the tables table
WITH table_schema AS (
    SELECT public.get_schema('tables')::jsonb AS schema
),
table_properties AS (
    SELECT jsonb_object_keys(schema->'properties') AS property_name
    FROM table_schema
),
expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'tables'
)
SELECT is(
    (SELECT COUNT(*) FROM table_properties),
    (SELECT COUNT(*) FROM expected_fields),
    'get_schema(tables) should include all fields from fields metadata'
);

-- Test that each expected field is present in the schema
SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'table_name'),
    'get_schema(tables) should include table_name'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'singular'),
    'get_schema(tables) should include singular'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'plural'),
    'get_schema(tables) should include plural'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'singular_label'),
    'get_schema(tables) should include singular_label'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'plural_label'),
    'get_schema(tables) should include plural_label'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'icon_url'),
    'get_schema(tables) should include icon_url'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'description'),
    'get_schema(tables) should include description'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'module_id'),
    'get_schema(tables) should include module_id'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'view_permission'),
    'get_schema(tables) should include view_permission'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'edit_permission'),
    'get_schema(tables) should include edit_permission'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'id_column'),
    'get_schema(tables) should include id_column'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'label_column'),
    'get_schema(tables) should include label_column'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'managed'),
    'get_schema(tables) should include managed'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'searchable'),
    'get_schema(tables) should include searchable'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'created_at'),
    'get_schema(tables) should include created_at'
);

SELECT ok(
    (SELECT public.get_schema('tables')::jsonb->'properties' ? 'updated_at'),
    'get_schema(tables) should include updated_at'
);

-- =====================================================
-- TEST: Verify get_schema() includes ALL field columns for fields table
-- =====================================================

-- Get the schema for the fields table
WITH field_schema AS (
    SELECT public.get_schema('fields')::jsonb AS schema
),
field_properties AS (
    SELECT jsonb_object_keys(schema->'properties') AS property_name
    FROM field_schema
),
expected_fields AS (
    SELECT field_name
    FROM fields
    WHERE table_name = 'fields'
)
SELECT is(
    (SELECT COUNT(*) FROM field_properties),
    (SELECT COUNT(*) FROM expected_fields),
    'get_schema(fields) should include all fields from fields metadata'
);

-- Test that new columns (enum_values, reference_table, reference_delete_mode) are present
SELECT ok(
    (SELECT public.get_schema('fields')::jsonb->'properties' ? 'enum_values'),
    'get_schema(fields) should include enum_values'
);

SELECT ok(
    (SELECT public.get_schema('fields')::jsonb->'properties' ? 'reference_table'),
    'get_schema(fields) should include reference_table'
);

SELECT ok(
    (SELECT public.get_schema('fields')::jsonb->'properties' ? 'reference_delete_mode'),
    'get_schema(fields) should include reference_delete_mode'
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
