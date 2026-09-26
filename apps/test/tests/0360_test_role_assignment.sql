-- The triggers that assign roles and permissions on their own: the User
-- role for every new user, assigned_by, and the Administrator auto-grant.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. User role auto-assignment and protection
--   2. user_roles.assigned_by default
--   3. New permissions are granted to Administrator
BEGIN;

SELECT plan(19);

-- =====================================================
-- PART 1: User role auto-assignment and protection
-- =====================================================
-- Test auto-assignment of role 1 and prevention of role 1 deletion

-- =====================================================
-- TEST: New users are automatically assigned role 1
-- =====================================================

-- Test 1: Create a new user and verify role 1 is auto-assigned
SELECT authenticate_as('user3'); -- user3 is the admin user with user:manage permission

-- Insert a new test user
INSERT INTO users (id, external_id, email) 
VALUES (9001, 'testuser1', 'testuser1@test.com');

-- Verify the user was created
SELECT ok(
    (SELECT COUNT(*) FROM users WHERE id = 9001) = 1,
    'New user with user_id 9001 should be created'
);

-- Verify role 1 was automatically assigned
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9001 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to new user 9001'
);

-- Test 2: Create another user and verify role 1 is auto-assigned
INSERT INTO users (id, external_id, email) 
VALUES (9002, 'testuser2', 'testuser2@test.com');

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9002 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to new user 9002'
);

-- Test 3: Verify the seeded user 1002 already has role 1 (precondition of test 6)
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1002 AND role_id = 1) = 1,
    'Existing user 1002 should have role 1 (User)'
);

-- =====================================================
-- TEST: Role 1 cannot be deleted from any user
-- =====================================================

-- Test 4: Attempt to delete role 1 from user 1001 should fail
SELECT throws_ok(
    'DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 1',
    '42501',
    'Cannot delete role 1 (User) from user. All users must have the User role.',
    'Deleting role 1 from user 1001 should raise an exception'
);

-- Test 5: Attempt to delete role 1 from newly created user should fail
SELECT throws_ok(
    'DELETE FROM user_roles WHERE user_id = 9001 AND role_id = 1',
    '42501',
    'Cannot delete role 1 (User) from user. All users must have the User role.',
    'Deleting role 1 from new user 9001 should raise an exception'
);

-- Test 6: Verify user 1002 still has role 1 after deletion attempt
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1002 AND role_id = 1) = 1,
    'User 1002 should still have role 1 after deletion attempt'
);

-- Test 7: Verify that other roles CAN be deleted.
-- Role 2 is given to user 9001 and taken away again, rather than taken from
-- user 1003: user 1003 is the only enabled Administrator, and removing the last
-- one is refused by rbac.assert_administrator_remains (pinned in
-- 0370_test_last_administrator.sql). With two holders the deletion is ordinary.
INSERT INTO user_roles (user_id, role_id) VALUES (9001, 2);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9001 AND role_id = 2) = 1,
    'User 9001 should have role 2 (Administrator) before deletion test'
);

-- Delete role 2 from user 9001 (this should succeed)
DELETE FROM user_roles WHERE user_id = 9001 AND role_id = 2;

-- Verify role 2 was successfully deleted
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9001 AND role_id = 2) = 0,
    'Role 2 (Administrator) should be successfully deleted from user 9001'
);

-- =====================================================
-- PART 2: user_roles.assigned_by default
-- =====================================================
-- Test that assigned_by defaults to the current user when not provided

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST: assigned_by defaults to current user on insert
-- =====================================================

-- Authenticate as user3 (admin with user:manage permission)
SELECT authenticate_as('user3');

-- Test 1: Insert a user_role without assigned_by — should default to current user
INSERT INTO user_roles (user_id, role_id)
VALUES (1001, 2);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1003::bigint,
    'assigned_by should default to current user (1003) when not provided'
);

-- Clean up for next test
DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2;

-- Test 2: Insert with explicit assigned_by — should preserve the provided value
INSERT INTO user_roles (user_id, role_id, assigned_by)
VALUES (1001, 2, 1002);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1002::bigint,
    'assigned_by should preserve explicit value (1002) when provided'
);

-- =====================================================
-- PART 3: New permissions are granted to Administrator
-- =====================================================
-- Test auto-grant new permissions to Administrator role

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- TEST: New permissions are automatically granted to Administrator role
-- =====================================================

-- Set up: authenticate as admin user
SELECT authenticate_as('user3');

-- Get Administrator role id
SELECT ok(
    (SELECT COUNT(*) FROM roles WHERE role_name = 'Administrator') = 1,
    'Administrator role should exist'
);

-- Get the current count of permissions for Administrator role before adding new permission
CREATE TEMP TABLE admin_permissions_before AS
SELECT permission_name FROM role_permissions WHERE role_id = (SELECT id FROM roles WHERE role_name = 'Administrator');

-- Test 1: Insert a new test permission
INSERT INTO permissions (permission_name, description, module_id) 
VALUES ('test:new_permission', 'Test permission for auto-grant feature', 1);

-- Get the id of the newly created permission
SELECT ok(
    (SELECT COUNT(*) FROM permissions WHERE permission_name = 'test:new_permission') = 1,
    'New test permission should be created'
);

-- Test 2: Verify that the new permission was automatically granted to Administrator role
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_name = p.permission_name
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'test:new_permission') = 1,
    'New permission should be automatically granted to Administrator role'
);

-- Test 3: Insert another test permission
INSERT INTO permissions (permission_name, description, module_id) 
VALUES ('test:another_permission', 'Another test permission for auto-grant feature', 1);

-- Verify that this permission was also automatically granted to Administrator role
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_name = p.permission_name
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'test:another_permission') = 1,
    'Second new permission should also be automatically granted to Administrator role'
);

-- Test 4: Verify that existing Administrator permissions are still intact
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_name = p.permission_name
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'admin') = 1,
    'Administrator role should still have the admin permission'
);

-- Test 5: Verify that the Administrator role now has more permissions than before
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions 
     WHERE role_id = (SELECT id FROM roles WHERE role_name = 'Administrator')) >
    (SELECT COUNT(*) FROM admin_permissions_before),
    'Administrator role should have more permissions after adding new ones'
);

-- Test 6: Insert a permission with a module_id
INSERT INTO permissions (permission_name, description, module_id) 
VALUES ('test:module_permission', 'Test permission with module for auto-grant feature',
        (SELECT id FROM modules WHERE module_slug = 'nwind'));

-- Verify that this permission was also automatically granted to Administrator role
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_name = p.permission_name
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'test:module_permission') = 1,
    'Permission with module_id should also be automatically granted to Administrator role'
);

-- Test 7: Verify that existing admin user (user3) has the new permissions
-- user3 already has the Administrator role from the seed data
SELECT authenticate_as('user3');

-- Verify user3 has the newly created permissions through Administrator role
SELECT ok(
    rbac.has_permission('test:new_permission') = TRUE,
    'Admin user should have the newly auto-granted permission through Administrator role'
);

SELECT * FROM finish();
ROLLBACK;
