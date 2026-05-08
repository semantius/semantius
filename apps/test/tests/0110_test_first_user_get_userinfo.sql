-- Test get_userinfo() for the first user (auto-admin) scenario
-- Verifies that when the very first user calls get_userinfo(),
-- they get Administrator role, admin permission, and ALL modules
BEGIN;

SELECT plan(10);

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

-- Test 9: Should see at least _core, CRM, and HR modules (ignoring any additional modules)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}, {"module_name": "CRM"}, {"module_name": "HR"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core, CRM, and HR modules'
);

-- Test 10: Should see _core module (requires admin permission)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core module'
);

SELECT * FROM finish();
ROLLBACK;
