-- Test public.get_userinfo() function
BEGIN;

SELECT plan(12);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user1
-- =====================================================
select authenticate_as('user1');

-- Test that get_userinfo() returns exactly one record
SELECT is(
    (SELECT COUNT(*)::integer FROM public.get_userinfo()),
    1,
    'get_userinfo() should return exactly one record for user1'
);

-- Test user_id
SELECT is(
    (SELECT user_id FROM public.get_userinfo()),
    1001,
    'get_userinfo() should return user_id 1001 for user1'
);

-- Test external_id
SELECT is(
    (SELECT external_id FROM public.get_userinfo()),
    'user1',
    'get_userinfo() should return external_id user1'
);

-- Test email
SELECT is(
    (SELECT email FROM public.get_userinfo()),
    'user@test.com',
    'get_userinfo() should return email user@test.com for user1'
);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user2
-- =====================================================
select authenticate_as('user2');

-- Test user_id
SELECT is(
    (SELECT user_id FROM public.get_userinfo()),
    1002,
    'get_userinfo() should return user_id 1002 for user2'
);

-- Test external_id
SELECT is(
    (SELECT external_id FROM public.get_userinfo()),
    'user2',
    'get_userinfo() should return external_id user2'
);

-- Test email
SELECT is(
    (SELECT email FROM public.get_userinfo()),
    'sales@test.com',
    'get_userinfo() should return email sales@test.com for user2'
);

-- Test is_disabled
SELECT is(
    (SELECT is_disabled FROM public.get_userinfo()),
    false,
    'get_userinfo() should return is_disabled false for user2'
);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user3
-- =====================================================
select authenticate_as('user3');

-- Test user_id
SELECT is(
    (SELECT user_id FROM public.get_userinfo()),
    1003,
    'get_userinfo() should return user_id 1003 for user3'
);

-- Test external_id
SELECT is(
    (SELECT external_id FROM public.get_userinfo()),
    'user3',
    'get_userinfo() should return external_id user3'
);

-- Test email
SELECT is(
    (SELECT email FROM public.get_userinfo()),
    'admin@test.com',
    'get_userinfo() should return email admin@test.com for user3'
);

-- Test that all timestamp fields are populated
SELECT ok(
    (SELECT created_at IS NOT NULL AND updated_at IS NOT NULL FROM public.get_userinfo()),
    'get_userinfo() should return non-null timestamp fields'
);

SELECT * FROM finish();
ROLLBACK;
