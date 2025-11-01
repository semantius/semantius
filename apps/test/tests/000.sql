-- Test that should fail
BEGIN;

SELECT plan(3);

-- Test that will pass
SELECT has_table('public', 'users', 'Users table should exist');

-- Test that will fail (checking for a column that doesn't exist)
SELECT has_column('public', 'users', 'nonexistent_column', 'Users table should have nonexistent_column');

-- Test that will also fail (checking for wrong number of records)
SELECT is(
    (SELECT COUNT(*) FROM users),
    5::bigint,
    'Should have 5 users but we only have 2'
);

SELECT * FROM finish();
ROLLBACK;