-- Test public.get_userinfo() function
BEGIN;

SELECT plan(20);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user1
-- =====================================================
select authenticate_as('user1');

-- Test that get_userinfo() returns JSON
SELECT ok(
    (SELECT public.get_userinfo() IS NOT NULL),
    'get_userinfo() should return a non-null JSON object for user1'
);

-- Test user_id
SELECT is(
    (SELECT (public.get_userinfo()->>'user_id')::integer),
    1001,
    'get_userinfo() should return user_id 1001 for user1'
);

-- Test external_id
SELECT is(
    (SELECT public.get_userinfo()->>'external_id'),
    'user1',
    'get_userinfo() should return external_id user1'
);

-- Test email
SELECT is(
    (SELECT public.get_userinfo()->>'email'),
    'user@test.com',
    'get_userinfo() should return email user@test.com for user1'
);

-- Test roles array exists
SELECT ok(
    (SELECT jsonb_typeof(public.get_userinfo()->'roles') = 'array'),
    'get_userinfo() should return roles as a JSON array for user1'
);

-- Test permissions array exists
SELECT ok(
    (SELECT jsonb_typeof(public.get_userinfo()->'permissions') = 'array'),
    'get_userinfo() should return permissions as a JSON array for user1'
);

-- Test user1 has User role
SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "User"}]'::jsonb),
    'get_userinfo() should show user1 has User role'
);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user2
-- =====================================================
select authenticate_as('user2');

-- Test user_id
SELECT is(
    (SELECT (public.get_userinfo()->>'user_id')::integer),
    1002,
    'get_userinfo() should return user_id 1002 for user2'
);

-- Test external_id
SELECT is(
    (SELECT public.get_userinfo()->>'external_id'),
    'user2',
    'get_userinfo() should return external_id user2'
);

-- Test email
SELECT is(
    (SELECT public.get_userinfo()->>'email'),
    'sales@test.com',
    'get_userinfo() should return email sales@test.com for user2'
);

-- Test is_disabled
SELECT is(
    (SELECT (public.get_userinfo()->>'is_disabled')::boolean),
    false,
    'get_userinfo() should return is_disabled false for user2'
);

-- Test user2 has both User and Sales User roles
SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "User"}]'::jsonb),
    'get_userinfo() should show user2 has User role'
);

SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "Sales User"}]'::jsonb),
    'get_userinfo() should show user2 has Sales User role'
);

-- Test user2 has sales:read permission
SELECT ok(
    (SELECT public.get_userinfo()->'permissions' @> '["sales:read"]'::jsonb),
    'get_userinfo() should show user2 has sales:read permission'
);

-- =====================================================
-- TEST: get_userinfo() returns correct data for user3
-- =====================================================
select authenticate_as('user3');

-- Test user_id
SELECT is(
    (SELECT (public.get_userinfo()->>'user_id')::integer),
    1003,
    'get_userinfo() should return user_id 1003 for user3'
);

-- Test external_id
SELECT is(
    (SELECT public.get_userinfo()->>'external_id'),
    'user3',
    'get_userinfo() should return external_id user3'
);

-- Test email
SELECT is(
    (SELECT public.get_userinfo()->>'email'),
    'admin@test.com',
    'get_userinfo() should return email admin@test.com for user3'
);

-- Test that all timestamp fields are populated
SELECT ok(
    (WITH info AS (SELECT public.get_userinfo() as data)
     SELECT (info.data->>'created_at') IS NOT NULL AND (info.data->>'updated_at') IS NOT NULL
     FROM info),
    'get_userinfo() should return non-null timestamp fields'
);

-- Test user3 has Administrator role
SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "Administrator"}]'::jsonb),
    'get_userinfo() should show user3 has Administrator role'
);

-- Test user3 has admin permission
SELECT ok(
    (SELECT public.get_userinfo()->'permissions' @> '["admin"]'::jsonb),
    'get_userinfo() should show user3 has admin permission'
);

SELECT * FROM finish();
ROLLBACK;
