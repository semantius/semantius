-- The triggers that assign roles and permissions on their own: the User
-- role for every new user, assigned_by and granted_by, and the Administrator
-- auto-grant.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. User role auto-assignment and protection
--   2. assigned_by and granted_by record the caller and cannot be changed
--   3. New permissions are granted to Administrator
--   4. Deleting the user who assigned a role or granted a permission
BEGIN;

SELECT plan(34);

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
-- PART 2: assigned_by and granted_by record the caller
-- =====================================================
-- The three columns name the user who handed out access, and only the
-- database writes them (rbac.record_actor in 0100_rbac_rls.sql): the caller on
-- INSERT, and the same value on every UPDATE. user3 holds admin and may write
-- all three tables, so user3 is exactly the caller who could otherwise make an
-- assignment look like another administrator's.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- The SQLSTATE and the hint of a refused statement, without the hint's text.
CREATE FUNCTION pg_temp.refusal(p_sql TEXT) RETURNS JSONB AS $$
    SELECT jsonb_build_object('sqlstate', e ->> 'code') || ((e ->> 'hint')::jsonb - 'hint')
    FROM (SELECT catch_error(p_sql) AS e) s;
$$ LANGUAGE sql;

SELECT authenticate_as('user3');

INSERT INTO user_roles (user_id, role_id)
VALUES (1001, 2);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1003::bigint,
    'assigned_by records the caller (1003) when not provided'
);

DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2;

SELECT is(
    pg_temp.refusal($$ INSERT INTO user_roles (user_id, role_id, assigned_by) VALUES (1001, 2, 1002) $$),
    '{"sqlstate": "42501", "code": "90109", "column": "assigned_by"}'::jsonb,
    'an INSERT naming another user as assigned_by is refused with 90109'
);

SELECT lives_ok(
    $$ INSERT INTO user_roles (user_id, role_id, assigned_by) VALUES (1001, 2, 1003) $$,
    'an INSERT naming the caller itself as assigned_by is accepted'
);

-- The assignment exists now, recorded as user3's. It cannot be moved to
-- another user, nor emptied.
SELECT is(
    pg_temp.refusal($$ UPDATE user_roles SET assigned_by = 1002 WHERE user_id = 1001 AND role_id = 2 $$),
    '{"sqlstate": "42501", "code": "90109", "column": "assigned_by"}'::jsonb,
    'an UPDATE that changes assigned_by is refused with 90109'
);

SELECT is(
    pg_temp.refusal($$ UPDATE user_roles SET assigned_by = NULL WHERE user_id = 1001 AND role_id = 2 $$),
    '{"sqlstate": "42501", "code": "90109", "column": "assigned_by"}'::jsonb,
    'an UPDATE that empties assigned_by is refused with 90109'
);

-- A client that saves a whole record sends the value back as it read it.
SELECT lives_ok(
    $$ UPDATE user_roles SET assigned_by = 1003 WHERE user_id = 1001 AND role_id = 2 $$,
    'an UPDATE that sends assigned_by unchanged is accepted'
);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1003::bigint,
    'assigned_by still names the user who made the assignment'
);

-- granted_by on role_permissions and user_permissions, through the same
-- trigger function.
INSERT INTO roles (role_name, slug, description)
VALUES ('Actor Probe Role', 'actor_probe_role', 'Holds grants made by user3');
INSERT INTO role_permissions (role_id, permission_name)
SELECT id, 'nwind:view' FROM roles WHERE slug = 'actor_probe_role';
INSERT INTO user_permissions (user_id, permission_name)
VALUES (1001, 'public:read');

SELECT is(
    pg_temp.refusal($$ INSERT INTO role_permissions (role_id, permission_name, granted_by)
                       SELECT id, 'nwind:manage', 1002 FROM roles WHERE slug = 'actor_probe_role' $$),
    '{"sqlstate": "42501", "code": "90109", "column": "granted_by"}'::jsonb,
    'an INSERT naming another user as granted_by of a role_permissions row is refused with 90109'
);

SELECT is(
    pg_temp.refusal($$ UPDATE role_permissions SET granted_by = 1002
                        WHERE permission_name = 'nwind:view'
                          AND role_id = (SELECT id FROM roles WHERE slug = 'actor_probe_role') $$),
    '{"sqlstate": "42501", "code": "90109", "column": "granted_by"}'::jsonb,
    'an UPDATE that changes granted_by of a role_permissions row is refused with 90109'
);

SELECT is(
    pg_temp.refusal($$ INSERT INTO user_permissions (user_id, permission_name, granted_by)
                       VALUES (1001, 'nwind:manage', 1002) $$),
    '{"sqlstate": "42501", "code": "90109", "column": "granted_by"}'::jsonb,
    'an INSERT naming another user as granted_by of a user_permissions row is refused with 90109'
);

SELECT is(
    pg_temp.refusal($$ UPDATE user_permissions SET granted_by = 1002
                        WHERE user_id = 1001 AND permission_name = 'public:read' $$),
    '{"sqlstate": "42501", "code": "90109", "column": "granted_by"}'::jsonb,
    'an UPDATE that changes granted_by of a user_permissions row is refused with 90109'
);

-- A role with BYPASSRLS is exempt: a migration or an import run as the owner
-- may record who really made an assignment. The claims are still user3's, so
-- the exemption, not the caller, is what lets this through.
RESET ROLE;
UPDATE user_roles SET assigned_by = 1002 WHERE user_id = 1001 AND role_id = 2;

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1002::bigint,
    'a role with BYPASSRLS may change assigned_by'
);

-- Without an authenticated caller there is nobody to record, so the
-- column stays NULL and the insert still succeeds. A direct owner connection
-- (a migration, a seed script) is the case: its claims are blank, and the
-- default must not turn that into an error.
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_external_id', '', true);

SELECT lives_ok(
    $$ INSERT INTO user_roles (user_id, role_id) VALUES (9002, 2) $$,
    'a user_roles insert without an authenticated caller is not refused'
);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 9002 AND role_id = 2),
    NULL::bigint,
    'assigned_by stays NULL when no caller can be resolved'
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

-- The Administrator is role 2 whatever its name: role 2 is renamed and
-- another role takes the name Administrator, and a new permission still goes
-- to role 2 and to no other role.
UPDATE roles SET role_name = 'Platform Administrator' WHERE id = 2;
INSERT INTO roles (role_name, slug, description) VALUES ('Administrator', 'name_only', 'Carries the name only');
INSERT INTO permissions (permission_name, description, module_id)
VALUES ('test:after_rename', 'Test permission created after role 2 was renamed', 1);

SELECT is(
    (SELECT array_agg(role_id ORDER BY role_id) FROM role_permissions WHERE permission_name = 'test:after_rename'),
    ARRAY[2]::bigint[],
    'a permission created after role 2 was renamed is granted to role 2 and to no other role'
);

-- =====================================================
-- PART 4: Deleting the user who assigned a role or granted a permission
-- =====================================================
-- assigned_by and granted_by record who made an assignment or a grant, as
-- references to users with delete mode clear. Deleting that user keeps the
-- assignment and the grants and empties the column.
--
-- The fixtures are written as the owner, which may record any user (part 2).
-- The delete runs as user3, who has no BYPASSRLS: emptying the columns is an
-- UPDATE that rbac.record_actor would refuse from user3, and it passes because
-- the foreign key's action runs as the referencing table's owner.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;

INSERT INTO users (id, external_id, email) VALUES (9101, 'by_probe', 'by_probe@test.com');
INSERT INTO roles (role_name, slug, description) VALUES ('By Probe Role', 'by_probe_role', 'Assigned and granted by the probe user');
INSERT INTO user_roles (user_id, role_id, assigned_by)
SELECT 1001, id, 9101 FROM roles WHERE slug = 'by_probe_role';
INSERT INTO role_permissions (role_id, permission_name, granted_by)
SELECT id, 'nwind:view', 9101 FROM roles WHERE slug = 'by_probe_role';
INSERT INTO user_permissions (user_id, permission_name, granted_by) VALUES (1001, 'nwind:view', 9101);

SELECT authenticate_as('user3');
SELECT lives_ok(
    $$ DELETE FROM users WHERE id = 9101 $$,
    'a user who assigned a role and granted permissions can be deleted'
);
RESET ROLE;

SELECT is(
    jsonb_build_array(
        (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
          WHERE r.slug = 'by_probe_role' AND ur.user_id = 1001 AND ur.assigned_by IS NULL),
        (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
          WHERE r.slug = 'by_probe_role' AND rp.permission_name = 'nwind:view' AND rp.granted_by IS NULL),
        (SELECT count(*) FROM user_permissions
          WHERE user_id = 1001 AND permission_name = 'nwind:view' AND granted_by IS NULL)),
    '[1, 1, 1]'::jsonb,
    'the assignment and both grants stay, with assigned_by and granted_by emptied'
);

SELECT * FROM finish();
ROLLBACK;
