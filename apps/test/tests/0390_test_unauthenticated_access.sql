-- Test the denied-by-default surface: a session with NO JWT claims must be
-- rejected on every access path — RLS-guarded tables, SECURITY DEFINER RPCs,
-- and rbac.uid() itself (all raise 42501 insufficient_privilege).
--
-- Also pins:
--   * malformed-claims variants (missing sub, wrong role claim)
--   * the authenticated -> semantius_user inheritance chain production
--     clients rely on (pgdocker/init/10-roles.sql, 0011_session_authenticator)
--   * the has_public_read() caller contract (the permission flag follows the
--     User role's public:read grant)
--   * the GRANT layer beneath RLS: a role outside semantius_user has neither
--     table SELECT nor EXECUTE on the public RPCs (0060 checks the REVOKEs
--     statically; this checks the resulting ACLs behaviorally)
--
-- Fixtures (0030_seed.sql): user1=1001 (User role only), user3=admin.
-- products_test is seeded with rows, so RLS policies actually evaluate.
BEGIN;

SELECT plan(16);

-- =====================================================
-- GROUP 1: no JWT claims at all
-- =====================================================
-- Switch to the runtime role WITHOUT setting any claims. A fresh transaction
-- has no request.jwt.claim.* GUCs, so this is exactly an unauthenticated
-- session (every other test authenticates via authenticate_as first).
SET ROLE semantius_user;

-- Test 1
SELECT throws_ok(
    $$ SELECT rbac.uid() $$,
    '42501', NULL,
    'unauth: rbac.uid() raises without JWT claims'
);

-- Test 2
SELECT throws_ok(
    $$ SELECT count(*) FROM public.products_test $$,
    '42501', NULL,
    'unauth: RLS-guarded data table SELECT raises (not silently empty)'
);

-- Test 3
SELECT throws_ok(
    $$ SELECT count(*) FROM public.users $$,
    '42501', NULL,
    'unauth: users table SELECT raises'
);

-- Test 4
SELECT throws_ok(
    $$ SELECT public.get_userinfo() $$,
    '42501', NULL,
    'unauth: get_userinfo() raises'
);

-- Test 5
SELECT throws_ok(
    $$ SELECT public.get_schemas('') $$,
    '42501', NULL,
    'unauth: get_schemas() raises'
);

-- Test 6
SELECT throws_ok(
    $$ SELECT public.has_permission('public:read') $$,
    '42501', NULL,
    'unauth: public.has_permission() raises'
);

-- Test 7
SELECT throws_ok(
    $$ SELECT public.has_public_read() $$,
    '42501', NULL,
    'unauth: has_public_read() raises'
);

-- =====================================================
-- GROUP 2: malformed claims
-- =====================================================

-- role claim present but sub empty
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', '', true);

-- Test 8
SELECT throws_like(
    $$ SELECT rbac.uid() $$,
    '%sub claim is missing%',
    'malformed: empty sub claim is rejected'
);

-- sub present but role claim is not authenticated
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claim.sub', 'user1', true);

-- Test 9
SELECT throws_like(
    $$ SELECT rbac.uid() $$,
    '%role claim must be authenticated%',
    'malformed: non-authenticated role claim is rejected'
);

-- =====================================================
-- GROUP 3: production role chain
-- =====================================================
-- Clients connect AS authenticated; its rights come entirely from
-- semantius_user membership. If that grant is lost, every real client is
-- locked out while the suite (which uses semantius_user directly) would
-- still pass — so pin it.

-- Test 10
SELECT ok(
    pg_has_role('authenticated', 'semantius_user', 'member'),
    'authenticated role inherits semantius_user'
);

-- =====================================================
-- GROUP 4: has_public_read() caller contract
-- =====================================================
-- The malformed claims from group 2 are still set and would make
-- authenticate_as()'s own users lookup fail under RLS — reset to the
-- session owner first so the lookup bypasses RLS.
RESET ROLE;
SELECT authenticate_as('user1');

-- Test 11
SELECT ok(
    (SELECT has_public_read() ?& ARRAY['current_role', 'is_member_of_semantius_user', 'has_public_read_permission']),
    'has_public_read() returns the three documented keys'
);

-- Test 12
SELECT is(
    (SELECT (has_public_read()->>'has_public_read_permission')::boolean),
    TRUE,
    'user1 (User role) reports has_public_read_permission = true'
);

-- Strip public:read from the User role; the flag must flip to false.
SELECT authenticate_as('user3');
DELETE FROM role_permissions
 WHERE role_id       = (SELECT id FROM roles       WHERE role_name       = 'User')
   AND permission_id = (SELECT id FROM permissions WHERE permission_name = 'public:read');

-- Re-authenticate to rebuild the cached permission list
SELECT authenticate_as('user1');

-- Test 13
SELECT is(
    (SELECT (has_public_read()->>'has_public_read_permission')::boolean),
    FALSE,
    'after revoking public:read from the User role the flag is false'
);

-- =====================================================
-- GROUP 5: GRANT layer beneath RLS (ACL introspection)
-- =====================================================
RESET ROLE;
CREATE ROLE tap_probe_no_priv NOLOGIN;

-- Test 14
SELECT ok(
    NOT has_table_privilege('tap_probe_no_priv', 'public.products_test', 'SELECT'),
    'a role outside semantius_user has no SELECT on data tables'
);

-- Test 15
SELECT ok(
    NOT has_function_privilege('tap_probe_no_priv', 'public.has_public_read()', 'EXECUTE'),
    'a role outside semantius_user cannot execute has_public_read()'
);

-- Test 16
SELECT ok(
    has_table_privilege('semantius_user', 'public.products_test', 'SELECT'),
    'control: semantius_user does hold SELECT on the same table'
);

SELECT * FROM finish();
ROLLBACK;
