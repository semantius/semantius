-- Basic RLS / rbac context smoke test.
--
-- Fixtures: harness identities from apps/test (user1 = 1001, User role only;
-- user2 = 1002, User + Northwind Sales) and the persisted nwind module
-- (products = 77 rows, view_permission 'nwind:view').
-- Also hosts the read-only lookup asserts for rbac.get_user_by_external_id()
-- (formerly in 0080_test_readonly_rls.sql).
BEGIN;

SELECT plan(12);

select authenticate_as('user1');

-- Test that will pass
SELECT has_table('public', 'users', 'Users table should exist');

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

-- Test that user1 has not nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    false,
    'user1 should not have nwind:view permission'
);

-- check that insert is blocked by RLS (roles requires admin permission).
-- module_id = 1 (_core) is a literal on purpose: user1 cannot see any module
-- row, so a slug subquery would resolve to NULL and the failure would no
-- longer isolate the RLS policy.
SELECT throws_ok(
    $$
    INSERT INTO roles (role_name, description, module_id)
    VALUES ('Should Fail', 'user1 lacks admin permission', 1);
    $$,
    '42501',
    NULL,
    'Insert into roles should fail because user1 lacks admin permission'
);

-- Read-only lookup helper (used by RLS in read-only transactions)
SELECT is(
    rbac.get_user_by_external_id('user1'),
    1001::integer,
    'rbac.get_user_by_external_id should return 1001 for user1'
);

SELECT is(
    rbac.get_user_by_external_id('does_not_exist'),
    NULL::integer,
    'rbac.get_user_by_external_id should return NULL for non-existent user'
);

select authenticate_as('user2');

-- Test rbac.uid() returns user2
SELECT is(
    rbac.uid(),
    'user2',
    'rbac.uid() should return user2'
);

-- Test product count - RLS should allow access (user2 holds nwind:view), so count should be 77
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    77,
    'Products table should contain 77 products for user2'
);

-- Test that user2 has nwind:view permission
SELECT is(
    rbac.has_permission('nwind:view'),
    true,
    'user2 should have nwind:view permission'
);

-- Test that an unknown permission name is simply false
SELECT is(
    rbac.has_permission('nwind:NOTEXISTANT'),
    false,
    'user2 should not have nwind:NOTEXISTANT'
);

SELECT * FROM finish();
ROLLBACK;
