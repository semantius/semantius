-- Test public.get_schemas() (multi-table wrapper around get_schema()).
--
-- Caller is user2 (nwind:view) reading the persisted nwind entity 'customers';
-- user1 cannot read nwind. Per-schema structure ($schema, title, properties,
-- table, required, children) is covered by 0110_test_get_schema.sql; here the
-- single-table result is pinned to be identical to get_schema() instead.
BEGIN;

SELECT plan(8);

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

-- Test that a table the user cannot access raises an error
-- (user2 does not have admin permission, so webhook_receivers is inaccessible)
SELECT throws_ok(
    'SELECT public.get_schemas(''customers, webhook_receivers'')',
    '42P01',
    'Table "webhook_receivers" not found in tables metadata',
    'get_schemas() should raise an error when the user lacks view permission for any table in the list'
);

SELECT * FROM finish();
ROLLBACK;
