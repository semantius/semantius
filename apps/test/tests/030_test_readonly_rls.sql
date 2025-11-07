-- Test that RLS works in read-only mode (e.g., PostgREST GET requests)
-- This test verifies that:
-- 1. get_userinfo() creates/updates user records
-- 2. After get_userinfo(), RLS policies work in read-only mode
-- 3. The new read-only function rbac.get_user_by_external_id() works correctly
-- 4. RLS policies fail with error when user doesn't exist

BEGIN;

SELECT plan(10);

-- =====================================================
-- TEST 1: Test read-only operations with existing users
-- =====================================================

-- Switch to user1 (exists from seed data)
select authenticate_as('user1');

-- Verify rbac.user_id() works (uses ensure_context_initialized internally)
SELECT is(
    rbac.user_id(),
    1001::integer,
    'rbac.user_id() should return 1001 for user1'
);

-- Verify permission checks work
SELECT is(
    rbac.has_permission('public:read'),
    true,
    'user1 should have public:read permission'
);

-- Switch to user2
select authenticate_as('user2');

-- Verify query on table with RLS works
SELECT is(
    (SELECT COUNT(*)::integer FROM products),
    3,
    'user2 should see 3 products through RLS'
);

-- =====================================================
-- TEST 2: Verify get_userinfo works correctly
-- =====================================================

-- Call get_userinfo and verify it returns data
SELECT ok(
    (SELECT COUNT(*) FROM public.get_userinfo()) = 1,
    'get_userinfo() should return one record'
);

-- Verify the function returns correct data
SELECT is(
    (SELECT user_id FROM public.get_userinfo()),
    1002::integer,
    'get_userinfo() should return user_id 1002 for user2'
);

SELECT is(
    (SELECT external_id FROM public.get_userinfo()),
    'user2',
    'get_userinfo() should return external_id user2'
);

-- =====================================================
-- TEST 3: Verify read-only function exists and works
-- =====================================================

-- Test that the new read-only function works
SELECT is(
    rbac.get_user_by_external_id('user1'),
    1001::integer,
    'rbac.get_user_by_external_id should return 1001 for user1'
);

-- Test that it returns NULL for non-existent user
SELECT is(
    rbac.get_user_by_external_id('does_not_exist'),
    NULL::integer,
    'rbac.get_user_by_external_id should return NULL for non-existent user'
);

-- =====================================================
-- TEST 4: Verify RLS fails with error when user doesn't exist
-- =====================================================

-- Set up JWT for a non-existent user
SET ROLE semantius_user;
SELECT set_config('request.jwt.claim.sub', 'nonexistent_user_12345', true);
SELECT set_config('request.jwt.claim.email', 'nonexistent@test.com', true);

-- Clear context to force re-initialization
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);

-- Test that RLS operation fails with proper error when user doesn't exist
SELECT throws_ok(
    $$
    SELECT rbac.has_permission('public:read');
    $$,
    '28000',
    NULL,
    'RLS should fail with error when user does not exist in database'
);

-- Test that querying RLS-protected table also fails
SELECT throws_ok(
    $$
    SELECT COUNT(*) FROM products;
    $$,
    '28000',
    NULL,
    'Querying RLS-protected table should fail when user does not exist'
);

SELECT * FROM finish();
ROLLBACK;
