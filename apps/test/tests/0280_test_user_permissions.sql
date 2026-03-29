-- Test user_permissions: direct per-user permission grants
BEGIN;

SELECT plan(11);

-- =====================================================
-- TEST 1: authenticate_as is not in public schema
-- =====================================================
-- PostgREST only exposes functions from its configured schema (public).
-- authenticate_as must live in pgtap schema so it cannot be called via the API.

SELECT is(
    (SELECT COUNT(*)::integer
     FROM pg_proc p
     JOIN pg_namespace n ON p.pronamespace = n.oid
     WHERE p.proname = 'authenticate_as'
       AND n.nspname = 'public'),
    0,
    'authenticate_as should not exist in public schema (not callable from PostgREST)'
);

-- =====================================================
-- TEST 2: user1 should not be able to read roles (no admin permission)
-- =====================================================

SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM roles),
    0,
    'user1 without admin permission should not be able to read roles'
);

RESET ROLE;

-- =====================================================
-- TEST 3: Assign admin permission directly to user1,
-- user1 should now be able to query roles
-- =====================================================

INSERT INTO user_permissions (user_id, permission_id)
SELECT u.id, p.id
FROM users u, permissions p
WHERE u.external_id = 'user1'
  AND p.permission_name = 'admin';

SELECT authenticate_as('user1');

SELECT cmp_ok(
    (SELECT COUNT(*)::integer FROM roles),
    '>',
    0,
    'user1 with direct admin permission should be able to query roles'
);

RESET ROLE;

-- Clean up: remove admin from user1
DELETE FROM user_permissions
WHERE user_id = (SELECT id FROM users WHERE external_id = 'user1')
  AND permission_id = (SELECT id FROM permissions WHERE permission_name = 'admin');

-- =====================================================
-- TEST 4: user_permissions table exists
-- =====================================================

SELECT has_table('public', 'user_permissions', 'user_permissions table should exist');

-- =====================================================
-- TEST 5: user_permissions has RLS enabled
-- =====================================================

SELECT is(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'user_permissions'),
    TRUE,
    'user_permissions table should have RLS enabled'
);

-- =====================================================
-- TEST 6: user_permissions entity metadata exists
-- =====================================================

SELECT is(
    (SELECT COUNT(*)::integer FROM entities WHERE table_name = 'user_permissions'),
    1,
    'user_permissions entity metadata should exist'
);

-- =====================================================
-- TEST 7: user_permissions fields metadata exists (5 fields: id, user_id, permission_id, granted_at, granted_by)
-- =====================================================

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'user_permissions'),
    5,
    'user_permissions should have 5 fields defined in metadata'
);

-- =====================================================
-- TEST 8: Create test:test permission, assign to user1,
-- delete the permission, verify user_permissions record is cascade-deleted
-- =====================================================

INSERT INTO permissions (permission_name, description)
VALUES ('test:test', 'Temporary test permission');

INSERT INTO user_permissions (user_id, permission_id)
SELECT u.id, p.id
FROM users u, permissions p
WHERE u.external_id = 'user1'
  AND p.permission_name = 'test:test';

-- Verify the record exists
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     JOIN permissions p ON up.permission_id = p.id
     WHERE p.permission_name = 'test:test'),
    1,
    'user_permissions should have test:test assigned to user1'
);

-- Delete the permission
DELETE FROM permissions WHERE permission_name = 'test:test';

-- Verify cascade deletion
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     WHERE up.permission_id NOT IN (SELECT id FROM permissions)),
    0,
    'Deleting a permission should cascade-delete user_permissions records'
);

-- =====================================================
-- TEST 10: Create a TEST user, assign admin permission,
-- delete the user, verify user_permissions record is cascade-deleted
-- =====================================================

INSERT INTO users (external_id, email) VALUES ('TEST', 'test_user@test.com');

INSERT INTO user_permissions (user_id, permission_id)
SELECT u.id, p.id
FROM users u, permissions p
WHERE u.external_id = 'TEST'
  AND p.permission_name = 'admin';

-- Verify record exists
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     JOIN users u ON up.user_id = u.id
     WHERE u.external_id = 'TEST'),
    1,
    'user_permissions should have admin assigned to TEST user'
);

-- Delete the user
DELETE FROM users WHERE external_id = 'TEST';

-- Verify cascade deletion
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     WHERE up.user_id NOT IN (SELECT id FROM users)),
    0,
    'Deleting a user should cascade-delete user_permissions records'
);

SELECT * FROM finish();
ROLLBACK;
