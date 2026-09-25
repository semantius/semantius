-- Test public.get_userinfo() function
--
-- Identity fixtures: user1 (User), user2 (User + Northwind Sales -> nwind:view),
-- user3 (User + Administrator). The modules arm uses the same ladder as
-- 0020_test_modules: two in-tx modules inserted as user3 ('Ladder Users' ->
-- user:read, 'Ladder Public' -> public:read) plus the persisted Northwind
-- (nwind:view) and _core (admin) modules.
BEGIN;

SELECT plan(35);

SELECT authenticate_as('user3');

INSERT INTO modules (module_name, module_slug, description, view_permission) VALUES
    ('Ladder Users',  'ladder_users',  'in-tx ladder rung', 'user:read'),
    ('Ladder Public', 'ladder_public', 'in-tx ladder rung', 'public:read');

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

-- Test display_name
SELECT is(
    (SELECT public.get_userinfo()->>'display_name'),
    'Test User',
    'get_userinfo() should return display_name Test User for user1'
);

-- Test first_name
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Test',
    'get_userinfo() should return first_name Test for user1'
);

-- Test last_name
SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'User',
    'get_userinfo() should return last_name User for user1'
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

-- Test display_name
SELECT is(
    (SELECT public.get_userinfo()->>'display_name'),
    'Sales Person',
    'get_userinfo() should return display_name Sales Person for user2'
);

-- Test first_name
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Sales',
    'get_userinfo() should return first_name Sales for user2'
);

-- Test last_name
SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'Person',
    'get_userinfo() should return last_name Person for user2'
);

-- Test is_disabled
SELECT is(
    (SELECT (public.get_userinfo()->>'is_disabled')::boolean),
    false,
    'get_userinfo() should return is_disabled false for user2'
);

-- Test user2 has both User and Northwind Sales roles
SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "User"}]'::jsonb),
    'get_userinfo() should show user2 has User role'
);

SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "Northwind Sales"}]'::jsonb),
    'get_userinfo() should show user2 has Northwind Sales role'
);

-- Test user2 has nwind:view permission
SELECT ok(
    (SELECT public.get_userinfo()->'permissions' @> '["nwind:view"]'::jsonb),
    'get_userinfo() should show user2 has nwind:view permission'
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

-- Test display_name
SELECT is(
    (SELECT public.get_userinfo()->>'display_name'),
    'Admin Boss',
    'get_userinfo() should return display_name Admin Boss for user3'
);

-- Test first_name
SELECT is(
    (SELECT public.get_userinfo()->>'first_name'),
    'Admin',
    'get_userinfo() should return first_name Admin for user3'
);

-- Test last_name
SELECT is(
    (SELECT public.get_userinfo()->>'last_name'),
    'Boss',
    'get_userinfo() should return last_name Boss for user3'
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

-- =====================================================
-- TEST: get_userinfo() includes modules array
-- =====================================================

-- Test user1 modules array exists
select authenticate_as('user1');
SELECT ok(
    (SELECT jsonb_typeof(public.get_userinfo()->'modules') = 'array'),
    'get_userinfo() should return modules as a JSON array for user1'
);

-- Test user1 can see both ladder modules (ignoring any additional modules)
SELECT ok(
    (SELECT public.get_userinfo()->'modules' @> '[{"module_name": "Ladder Users"}, {"module_name": "Ladder Public"}]'::jsonb),
    'user1 should see the Ladder Users and Ladder Public modules'
);

-- Test user2 modules should include Northwind (ignoring any additional modules)
select authenticate_as('user2');
SELECT ok(
    (SELECT public.get_userinfo()->'modules' @> '[{"module_name": "Northwind"}]'::jsonb),
    'user2 should see the Northwind module'
);

-- Test user3 (admin) modules should include _core and Northwind (ignoring any additional modules)
select authenticate_as('user3');
SELECT ok(
    (SELECT public.get_userinfo()->'modules' @> '[{"module_name": "_core"}, {"module_name": "Northwind"}]'::jsonb),
    'user3 (admin) should see _core and Northwind modules'
);

-- Test _core module has logo_url
SELECT ok(
    (SELECT public.get_userinfo()->'modules' @> '[{"module_name": "_core"}]'::jsonb),
    'user3 (admin) should see _core module in modules array'
);

-- Test _core module has logo_color
SELECT is(
    (SELECT module->>'logo_color' 
     FROM jsonb_array_elements(public.get_userinfo()->'modules') AS module
     WHERE module->>'module_name' = '_core' 
     LIMIT 1),
    '#029948',
    '_core module should have logo_color set to #029948'
);

SELECT * FROM finish();
ROLLBACK;
