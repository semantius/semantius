-- Test that JWT claims update user records on subsequent logins
-- Verifies that given_name (first_name) and family_name (last_name) are
-- updated when a user calls get_userinfo() with new JWT claims
BEGIN;

SELECT plan(8);

-- =====================================================
-- TEST: Claims are stored on first call
-- =====================================================
SELECT authenticate_as('user1');

-- Verify initial first_name and last_name
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Test',
    'user1 should have first_name Test initially'
);

SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'User',
    'user1 should have last_name User initially'
);

-- =====================================================
-- TEST: Claims are updated on subsequent login with new values
-- =====================================================

-- Simulate user1 logging in with updated JWT claims
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', 'user1', true);
SELECT set_config('request.jwt.claim.email', 'user@test.com', true);
SELECT set_config('request.jwt.claim.given_name', 'Updated', true);
SELECT set_config('request.jwt.claim.family_name', 'Name', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.aud', '', true);

-- Clear context
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);
SELECT set_config('app.oauth_scopes', NULL, false);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- Call get_userinfo which should update the user record
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Updated',
    'user1 first_name should be updated to Updated after new JWT claims'
);

SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'Name',
    'user1 last_name should be updated to Name after new JWT claims'
);

-- =====================================================
-- TEST: sub (external_id) never changes
-- =====================================================
SELECT is(
    (SELECT public.get_userinfo()->>'external_id'),
    'user1',
    'external_id should remain user1 and never change'
);

-- =====================================================
-- TEST: Empty claims do NOT overwrite existing values
-- =====================================================

-- Simulate login with empty given_name/family_name
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', 'user1', true);
SELECT set_config('request.jwt.claim.email', 'user@test.com', true);
SELECT set_config('request.jwt.claim.given_name', '', true);
SELECT set_config('request.jwt.claim.family_name', '', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.aud', '', true);

SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);
SELECT set_config('app.oauth_scopes', NULL, false);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- first_name and last_name should keep the previously updated values
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Updated',
    'first_name should not be overwritten by empty JWT claim'
);

SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'Name',
    'last_name should not be overwritten by empty JWT claim'
);

-- =====================================================
-- TEST: external_id UNIQUE constraint exists
-- =====================================================
RESET ROLE;
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'users'
          AND constraint_type = 'UNIQUE'
          AND constraint_name LIKE '%external_id%'
    )),
    'users table should have a UNIQUE constraint on external_id'
);

SELECT * FROM finish();
ROLLBACK;
