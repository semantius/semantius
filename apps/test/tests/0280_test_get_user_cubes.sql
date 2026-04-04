-- Test public.get_user_cubes() function
BEGIN;

SELECT plan(2);

-- =====================================================
-- TEST 1: user1 cannot see role_permissions
-- user1 has user:read and public:read permissions only.
-- role_permissions requires 'admin' permission, so it must not appear.
-- =====================================================

SELECT authenticate_as('user1');

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public.get_user_cubes('_core') AS s
        WHERE s->'table'->>'table_name' = 'role_permissions'
    ),
    'user1 should not see role_permissions in _core cube (requires admin permission)'
);

-- =====================================================
-- TEST 2: user3 can see role_permissions
-- user3 has the Administrator role which includes 'admin' permission.
-- role_permissions requires 'admin', so it must appear.
-- =====================================================

SELECT authenticate_as('user3');

SELECT ok(
    EXISTS (
        SELECT 1 FROM public.get_user_cubes('_core') AS s
        WHERE s->'table'->>'table_name' = 'role_permissions'
    ),
    'user3 should see role_permissions in _core cube (has admin permission)'
);

SELECT * FROM finish();
ROLLBACK;
