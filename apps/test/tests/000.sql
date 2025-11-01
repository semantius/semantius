-- Test that should fail
BEGIN;

SELECT plan(3);

select authenticate_as('user1', 'user@test.com');

-- Test that will pass
SELECT has_table('public', 'users', 'Users table should exist');

-- Test that will fail (checking for a column that doesn't exist)
-- SELECT has_column('public', 'users', 'nonexistent_column', 'Users table should have nonexistent_column');

-- SELECT diag('Type: ' || pg_typeof(rbac.user_id())::text);
-- SELECT diag('Value: ' || coalesce(rbac.uid()::text, '<NULL>'));

-- Test rbac.user_id() returns 1001
SELECT is(
    rbac.user_id(),
    1001::integer,
    'rbac.user_id() should return 1001'
);

-- Test rbac.uid() returns user1
SELECT is(
    rbac.uid(),
    'user1',
    'rbac.uid() should return user1'
);

SELECT * FROM finish();
ROLLBACK;