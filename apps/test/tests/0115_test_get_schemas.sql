-- Test public.get_schemas() function
BEGIN;

SELECT plan(18);

-- =====================================================
-- TEST: get_schemas() returns correct data
-- =====================================================
select authenticate_as('user1');

-- Test that get_schemas() returns a JSON array for a single table
SELECT ok(
    public.get_schemas('customers_test') IS NOT NULL,
    'get_schemas() should return a non-null JSON value'
);

-- Test that get_schemas() returns an array type
SELECT ok(
    json_typeof(public.get_schemas('customers_test')) = 'array',
    'get_schemas() should return a JSON array'
);

-- Test that a single-table call returns an array with one element
SELECT is(
    json_array_length(public.get_schemas('customers_test')),
    1,
    'get_schemas() with one table name should return an array with one element'
);

-- Test that the single element has the expected title
SELECT is(
    (public.get_schemas('customers_test')::jsonb)->0->>'title',
    'Customer',
    'get_schemas() element 0 should have the correct title'
);

-- Test that multiple tables return an array with two elements
SELECT is(
    json_array_length(public.get_schemas('customers_test, products_test')),
    2,
    'get_schemas() with two table names should return an array with two elements'
);

-- Test that the first element matches the first requested table
SELECT is(
    (public.get_schemas('customers_test, products_test')::jsonb)->0->>'title',
    'Customer',
    'get_schemas() element 0 should match the first requested table'
);

-- Test that the second element matches the second requested table
SELECT is(
    (public.get_schemas('customers_test, products_test')::jsonb)->1->>'title',
    'Product',
    'get_schemas() element 1 should match the second requested table'
);

-- Test that each schema in the array has the expected structure ($schema field)
SELECT is(
    (public.get_schemas('customers_test')::jsonb)->0->>'$schema',
    'https://semantius.com/meta/sem-schema/v1',
    'get_schemas() element should contain $schema field'
);

-- Test that each schema has a properties object
SELECT ok(
    jsonb_typeof((public.get_schemas('customers_test')::jsonb)->0->'properties') = 'object',
    'get_schemas() element should have a properties object'
);

-- Test that each schema has a table object
SELECT ok(
    jsonb_typeof((public.get_schemas('customers_test')::jsonb)->0->'table') = 'object',
    'get_schemas() element should have a table object'
);

-- Test that each schema has a required array
SELECT ok(
    jsonb_typeof((public.get_schemas('customers_test')::jsonb)->0->'required') = 'array',
    'get_schemas() element should have a required array'
);

-- Test that each schema has a children array
SELECT ok(
    jsonb_typeof((public.get_schemas('customers_test')::jsonb)->0->'children') = 'array',
    'get_schemas() element should have a children array'
);

-- Test empty string returns empty array (blank entries are always skipped)
SELECT is(
    json_array_length(public.get_schemas('')),
    0,
    'get_schemas() with empty string should return empty array'
);

-- Test that get_schemas() output matches get_schema() for the same table
SELECT is(
    (public.get_schemas('customers_test')::jsonb)->0,
    public.get_schema('customers_test')::jsonb,
    'get_schemas() single-table result should match get_schema() output exactly'
);

-- Test that get_schemas() output matches get_schema() for second table
SELECT is(
    (public.get_schemas('customers_test, products_test')::jsonb)->1,
    public.get_schema('products_test')::jsonb,
    'get_schemas() multi-table result should match get_schema() output for each table'
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
    'SELECT public.get_schemas(''customers_test, nonexistent_table_xyz'')',
    '42P01',
    'Table "nonexistent_table_xyz" not found in entities',
    'get_schemas() should raise an error even when only one table in the list does not exist'
);

-- Test that a table the user cannot access raises an error
-- (user1 does not have admin permission, so webhook_receivers is inaccessible)
SELECT throws_ok(
    'SELECT public.get_schemas(''customers_test, webhook_receivers'')',
    '42P01',
    'Table "webhook_receivers" not found in tables metadata',
    'get_schemas() should raise an error when the user lacks view permission for any table in the list'
);

SELECT * FROM finish();
ROLLBACK;
