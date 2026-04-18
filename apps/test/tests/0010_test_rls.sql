-- Test that should fail
BEGIN;

SELECT plan(10);

select authenticate_as('user1');

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

-- Test webhook_receivers count - RLS should prevent access (requires admin permission), so count should be 0
SELECT is(
    (SELECT COUNT(*)::integer FROM webhook_receivers),
    0,
    'webhook_receivers table should contain 0 records (user1 lacks admin permission)'
);

-- Test that user1 has not sales:read permission
SELECT is(
    rbac.has_permission('sales:read'),
    false,
    'user1 should not have sales:read permission'
);

-- check that insert is blocked by RLS
SELECT throws_ok(
    $$
    INSERT INTO products_test (
        product_name, sku, description, price, quantity_in_stock, is_discontinued
    )
    VALUES
        ('XXX', 'WGT-001', 'Should fail', 29.99, 150, FALSE);
    $$,
    '42501',
    NULL,
    'Insert should fail because of RLS policy'
);

select authenticate_as('user2');

-- Test rbac.uid() returns user2
SELECT is(
    rbac.uid(),
    'user2',
    'rbac.uid() should return user2'
);

-- Test product count - RLS should allow access, so count should be 3
SELECT is(
    (SELECT COUNT(*)::integer FROM products_test),
    3,
    'Products table should contain 3 products'
);

-- Test that user2 has sales:read permission
SELECT is(
    rbac.has_permission('sales:read'),
    true,
    'user2 should have sales:read permission'
);

-- Test that user2 has sales:read permission
SELECT is(
    rbac.has_permission('sales:NOTEXISTANT'),
    false,
    'user2 should not have sales:read NOTEXISTANT'
);

SELECT * FROM finish();
ROLLBACK;