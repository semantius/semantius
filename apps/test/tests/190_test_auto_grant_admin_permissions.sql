-- Test auto-grant new permissions to Administrator role
BEGIN;

SELECT plan(8);

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
SELECT permission_id FROM role_permissions WHERE role_id = (SELECT id FROM roles WHERE role_name = 'Administrator');

-- Test 1: Insert a new test permission
INSERT INTO permissions (permission_name, description) 
VALUES ('test:new_permission', 'Test permission for auto-grant feature');

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
     JOIN permissions p ON rp.permission_id = p.id
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'test:new_permission') = 1,
    'New permission should be automatically granted to Administrator role'
);

-- Test 3: Insert another test permission
INSERT INTO permissions (permission_name, description) 
VALUES ('test:another_permission', 'Another test permission for auto-grant feature');

-- Verify that this permission was also automatically granted to Administrator role
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_id = p.id
     WHERE r.role_name = 'Administrator' 
       AND p.permission_name = 'test:another_permission') = 1,
    'Second new permission should also be automatically granted to Administrator role'
);

-- Test 4: Verify that existing Administrator permissions are still intact
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_id = p.id
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
VALUES ('test:module_permission', 'Test permission with module for auto-grant feature', 1001);

-- Verify that this permission was also automatically granted to Administrator role
SELECT ok(
    (SELECT COUNT(*) 
     FROM role_permissions rp
     JOIN roles r ON rp.role_id = r.id
     JOIN permissions p ON rp.permission_id = p.id
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
