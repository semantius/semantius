-- Test that RLS works in read-only mode (e.g., PostgREST GET requests)
-- This test verifies that:
-- 1. get_userinfo() creates/updates user records
-- 2. After get_userinfo(), RLS policies work in read-only mode
-- 3. The new read-only function rbac.get_user_by_external_id() works correctly

BEGIN;

SELECT plan(8);

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

SELECT * FROM finish();
ROLLBACK;
