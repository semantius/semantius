-- Test that admin role can read products table
BEGIN;

SELECT plan(5);

-- =====================================================
-- TEST: Authenticate as user3 (Administrator)
-- =====================================================
SELECT authenticate_as('user3');

-- Test rbac.uid() returns user3
SELECT is(
    rbac.uid(),
    'user3',
    'rbac.uid() should return user3'
);

-- Test that user3 has user:read permission (inherited via user:manage)
SELECT is(
    rbac.has_permission('user:read'),
    true,
    'user3 (Administrator) should have user:read permission'
);

-- Test that user3 has admin permission
SELECT is(
    rbac.has_permission('admin'),
    true,
    'user3 (Administrator) should have admin permission'
);

-- Test product count - Administrator should be able to read products
-- because products table has view_permission='user:read' and
-- Administrator role has user:manage which implies user:read
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    3,
    'Administrator should be able to read products table (count should be 3)'
);

-- Test that user3 can select specific product details
SELECT ok(
    EXISTS(
        SELECT 1 
        FROM products 
        WHERE product_name = 'Widget Pro' 
        AND sku = 'WGT-001'
    ),
    'Administrator should be able to read specific product details'
);

SELECT * FROM finish();
ROLLBACK;
