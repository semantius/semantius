-- Test get_userinfo() for the first user (auto-admin) scenario
-- Verifies that when the very first user calls get_userinfo(),
-- they get Administrator role, admin permission, and ALL modules
-- (persisted: _core + Northwind).
-- Also pins the bootstrap negatives (formerly 0100_test_first_user_admin):
-- once a seen user exists, a second user created WITH last_seen and a user
-- created with last_seen NULL both get role 1 (User) but NOT role 2.
BEGIN;

SELECT plan(17);

-- =====================================================
-- SETUP: Simulate a fresh system with no active users
-- =====================================================

-- Use admin to clear last_seen on all existing test users
SELECT authenticate_as('user3');
UPDATE users SET last_seen = NULL WHERE id IN (1001, 1002, 1003);

-- Switch to postgres role to set up JWT claims for a user that doesn't exist yet
-- (authenticate_as requires the user to already exist, but we need get_userinfo to create them)
RESET ROLE;

-- Set JWT claims for a brand-new user
SELECT set_config('request.jwt.claim.sub', 'firstuser_ui', true);
SELECT set_config('request.jwt.claim.email', 'firstadmin@test.com', true);
SELECT set_config('request.jwt.claim.name', 'First Admin', true);
SELECT set_config('request.jwt.claim.given_name', 'First', true);
SELECT set_config('request.jwt.claim.family_name', 'Admin', true);

-- Clear any cached context from previous authenticate_as call
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);
SELECT set_config('app.oauth_scopes', NULL, false);

-- Switch to the application role (simulating a real API request)
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- =====================================================
-- TEST: Call get_userinfo() as a brand-new first user
-- Store result once to test the actual first-call behavior
-- =====================================================

CREATE TEMP TABLE first_user_info AS
SELECT public.get_userinfo() AS info;

-- Test 1: get_userinfo() should succeed and return non-null
SELECT ok(
    (SELECT info IS NOT NULL FROM first_user_info),
    'get_userinfo() should succeed for a brand-new first user'
);

-- Test 2: Should have correct email
SELECT is(
    (SELECT info->>'email' FROM first_user_info),
    'firstadmin@test.com',
    'First user should have correct email'
);

-- Test 2b: Should have correct display_name from JWT name
SELECT is(
    (SELECT info->>'display_name' FROM first_user_info),
    'First Admin',
    'First user should have display_name from JWT name'
);

-- Test 2c: Should have correct first_name from JWT given_name
SELECT is(
    (SELECT info->>'first_name' FROM first_user_info),
    'First',
    'First user should have first_name from JWT given_name'
);

-- Test 2d: Should have correct last_name from JWT family_name
SELECT is(
    (SELECT info->>'last_name' FROM first_user_info),
    'Admin',
    'First user should have last_name from JWT family_name'
);

-- Test 3: Should have User role
SELECT ok(
    (SELECT info->'roles' @> '[{"role_name": "User"}]'::jsonb FROM first_user_info),
    'First user should have User role'
);

-- Test 4: Should have Administrator role (auto-assigned as first user)
SELECT ok(
    (SELECT info->'roles' @> '[{"role_name": "Administrator"}]'::jsonb FROM first_user_info),
    'First user should have Administrator role (auto-assigned)'
);

-- Test 5: Should have admin permission
SELECT ok(
    (SELECT info->'permissions' @> '["admin"]'::jsonb FROM first_user_info),
    'First user should have admin permission'
);

-- Test 6: Should have user:read permission
SELECT ok(
    (SELECT info->'permissions' @> '["user:read"]'::jsonb FROM first_user_info),
    'First user should have user:read permission'
);

-- Test 7: Should have user:manage permission
SELECT ok(
    (SELECT info->'permissions' @> '["user:manage"]'::jsonb FROM first_user_info),
    'First user should have user:manage permission'
);

-- Test 8: Modules should NOT be empty
SELECT ok(
    (SELECT jsonb_array_length(info->'modules') > 0 FROM first_user_info),
    'First user (admin) modules should not be empty'
);

-- Test 9: Should see at least _core and Northwind modules (ignoring any additional modules)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}, {"module_name": "Northwind"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core and Northwind modules'
);

-- Test 10: Should see _core module (requires admin permission)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core module'
);

-- =====================================================
-- TEST: bootstrap negatives - only the FIRST seen user becomes admin
-- =====================================================
-- The first user above now has last_seen set, so nobody created afterwards
-- may receive role 2. Insert as user3 (user:manage); last_seen of user3 is
-- irrelevant to its permissions.
RESET ROLE;
SELECT authenticate_as('user3');

-- Test 11/12: a second user created WITH last_seen gets role 1 but NOT role 2
INSERT INTO users (id, external_id, email, last_seen)
VALUES (9902, 'seconduser', 'second@test.com', CURRENT_TIMESTAMP);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to second user'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to second user'
);

-- Test 13/14: a user created WITHOUT last_seen gets role 1 but NOT role 2
INSERT INTO users (id, external_id, email, last_seen)
VALUES (9903, 'thirduser', 'third@test.com', NULL);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 1) = 1,
    'Role 1 (User) should be assigned to user without last_seen'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to user without last_seen'
);

SELECT * FROM finish();
ROLLBACK;
