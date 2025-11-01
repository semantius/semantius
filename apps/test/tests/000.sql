-- Test that should fail
BEGIN;

SELECT plan(8);

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

-- Test product count - RLS should prevent access, so count should be 0
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    0,
    'Products table should contain 0 products'
);

-- Test that user1 has not sales:read permission
SELECT is(
    rbac.has_permission('sales:read'),
    false,
    'user1 should have sales:read permission'
);

select authenticate_as('user2', 'sales@test.com');

-- Test rbac.uid() returns user2
SELECT is(
    rbac.uid(),
    'user2',
    'rbac.uid() should return user2'
);

-- Test product count - RLS should allow access, so count should be 3
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    3,
    'Products table should contain 3 products'
);

-- Test that user2 has sales:read permission
SELECT is(
    rbac.has_permission('sales:read'),
    true,
    'user2 should have sales:read permission'
);


SELECT * FROM finish();
ROLLBACK;