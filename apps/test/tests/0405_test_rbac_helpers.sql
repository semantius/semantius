-- =====================================================
-- RBAC helper functions (0405)
-- =====================================================
-- The first coverage run (docs/pg_semantius-test-coverage.md) showed these
-- rbac helpers were never executed by the suite: has_any_permission,
-- require_any_permission, user_has_permission, get_current_user_permissions,
-- validate_oauth_scopes, whoami, the OAuth-scope branches of has_permission,
-- and public.ping. This file pins their current behavior.
--
-- Fixtures are the seeded identities only: user1 (User role, no module
-- permissions), user2 (Northwind Sales: nwind:view + nwind:manage), user3
-- (Administrator). Nothing is persisted; the OAuth scope GUC is
-- transaction-local and reset between groups.
--
-- Scope format note (pinned as-is): has_permission / has_any_permission read
-- app.oauth_scopes as a comma-separated list, user_has_permission reads it as
-- a space-separated list. The tests use single-scope values so they hold under
-- both readers.
BEGIN;

SELECT plan(41);

-- =====================================================
-- GROUP 1: has_any_permission / require_any_permission (user2)
-- =====================================================
SELECT authenticate_as('user2');

SELECT ok(rbac.has_any_permission('nwind:manage', 'admin'),
    'has_any_permission: true when at least one listed permission is held');
SELECT ok(rbac.has_any_permission('admin', 'nwind:view'),
    'has_any_permission: order of the list does not matter');
SELECT ok(NOT rbac.has_any_permission('admin', 'user:manage'),
    'has_any_permission: false when none of the listed permissions is held');
SELECT ok(NOT rbac.has_any_permission(VARIADIC ARRAY[]::text[]),
    'has_any_permission: empty list is false');
SELECT ok(NOT rbac.has_any_permission(VARIADIC NULL::text[]),
    'has_any_permission: NULL list is false');
SELECT ok(NOT rbac.has_any_permission('no:such:permission'),
    'has_any_permission: unknown permission name is false');

SELECT lives_ok($$SELECT rbac.require_any_permission('admin', 'nwind:view')$$,
    'require_any_permission: passes when one of the permissions is held');
SELECT throws_ok($$SELECT rbac.require_any_permission('admin', 'user:manage')$$,
    '42501', NULL,
    'require_any_permission: raises insufficient_privilege when none is held');
SELECT throws_like($$SELECT rbac.require_any_permission('admin', 'user:manage')$$,
    '%one of (admin, user:manage) required%',
    'require_any_permission: the message lists the acceptable permissions');

-- =====================================================
-- GROUP 2: get_current_user_permissions / whoami (user2)
-- =====================================================
SELECT set_eq(
    $$SELECT permission_name FROM rbac.get_current_user_permissions() WHERE permission_name LIKE 'nwind:%'$$,
    ARRAY['nwind:view', 'nwind:manage'],
    'get_current_user_permissions: lists the Northwind permissions of user2');
SELECT ok(NOT EXISTS (SELECT 1 FROM rbac.get_current_user_permissions() WHERE permission_name = 'admin'),
    'get_current_user_permissions: user2 does not hold admin');

SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'app' AND key = 'current_external_id'),
    'user2', 'whoami: app.current_external_id is the JWT sub');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'app' AND key = 'current_user_id'),
    '1002', 'whoami: app.current_user_id is the internal user id');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'status' AND key = 'context_initialized'),
    'true', 'whoami: the request context is initialized');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'jwt' AND key = 'role'),
    'authenticated', 'whoami: the normalized role claim is reported');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'jwt' AND key = 'email'),
    'sales@test.com', 'whoami: the email claim is reported');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'jwt_raw' AND key = 'request.jwt.claim.sub'),
    'user2', 'whoami: the raw sub setting is reported');
SELECT ok((SELECT value FROM rbac.whoami() WHERE context_type = 'app' AND key = 'user_permissions') LIKE '%nwind:manage%',
    'whoami: the cached permission list contains nwind:manage');
SELECT is((SELECT count(*)::int FROM rbac.whoami() WHERE context_type = 'jwt' AND key = 'picture'),
    0, 'whoami: claims that are not set are omitted');

-- =====================================================
-- GROUP 3: OAuth scope restriction on the cached permissions (user2)
-- =====================================================
SELECT set_config('app.oauth_scopes', 'nwind:view', true);

SELECT ok(rbac.has_permission('nwind:view'),
    'has_permission: a held permission inside the OAuth scope list is allowed');
SELECT ok(NOT rbac.has_permission('nwind:manage'),
    'has_permission: a held permission outside the OAuth scope list is denied');
SELECT ok(rbac.has_any_permission('nwind:manage', 'nwind:view'),
    'has_any_permission: allowed when one name is both held and in scope');
SELECT ok(NOT rbac.has_any_permission('nwind:manage'),
    'has_any_permission: denied when the held name is outside the scope');
SELECT throws_ok($$SELECT rbac.require_any_permission('nwind:manage')$$,
    '42501', NULL,
    'require_any_permission: OAuth scope restriction raises insufficient_privilege');

SELECT set_config('app.oauth_scopes', '', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'has_permission: an empty scope list means no scope restriction');

-- =====================================================
-- GROUP 4: user_has_permission / validate_oauth_scopes (user3, admin)
-- =====================================================
SELECT authenticate_as('user3');

SELECT ok(rbac.user_has_permission('user2', 'nwind:view'),
    'user_has_permission: user2 holds nwind:view through the Northwind Sales role');
SELECT ok(NOT rbac.user_has_permission('user1', 'nwind:view'),
    'user_has_permission: user1 does not hold nwind:view');
SELECT ok(NOT rbac.user_has_permission('user2', 'no:such:permission'),
    'user_has_permission: unknown permission name is false');
SELECT ok(NOT rbac.user_has_permission('nobody', 'nwind:view'),
    'user_has_permission: unknown user is false');
SELECT ok(NOT rbac.user_has_permission('', 'nwind:view'),
    'user_has_permission: empty external_id is false');
SELECT ok(NOT rbac.user_has_permission('user2', ''),
    'user_has_permission: empty permission name is false');

SELECT set_config('app.oauth_scopes', 'nwind:view', true);
SELECT ok(rbac.user_has_permission('user2', 'nwind:view'),
    'user_has_permission: a permission inside the scope list stays granted');
SELECT ok(NOT rbac.user_has_permission('user2', 'nwind:manage'),
    'user_has_permission: a permission outside the scope list is denied');
SELECT set_config('app.oauth_scopes', 'nwind:manage', true);
SELECT ok(rbac.user_has_permission('user2', 'nwind:view'),
    'user_has_permission: a scope that implies the permission via permission_hierarchy grants it');
SELECT set_config('app.oauth_scopes', '', true);

SELECT results_eq(
    $$SELECT scope, is_valid FROM rbac.validate_oauth_scopes('user2', 'nwind:view admin') ORDER BY scope$$,
    $$VALUES ('admin'::text, false), ('nwind:view'::text, true)$$,
    'validate_oauth_scopes: reports which requested scopes the user holds');
SELECT is((SELECT reason FROM rbac.validate_oauth_scopes('user2', 'admin')),
    'User does not have this permission', 'validate_oauth_scopes: reason for a scope the user lacks');
SELECT is((SELECT reason FROM rbac.validate_oauth_scopes('user2', 'nwind:view')),
    'Granted', 'validate_oauth_scopes: reason for a scope the user holds');
SELECT is((SELECT count(*)::int FROM rbac.validate_oauth_scopes('user2', '')),
    0, 'validate_oauth_scopes: an empty request yields no rows');
SELECT throws_ok($$SELECT * FROM rbac.validate_oauth_scopes('', 'nwind:view')$$,
    'P0001', 'external_id cannot be null or empty',
    'validate_oauth_scopes: empty external_id is rejected');

-- =====================================================
-- GROUP 5: public.ping (user1)
-- =====================================================
SELECT authenticate_as('user1');

SELECT is((SELECT current_user_name FROM public.ping()), 'semantius_user',
    'ping: reports the request role as current_user');
SELECT ok((SELECT server_time FROM public.ping()) BETWEEN now() - interval '1 minute' AND now() + interval '1 minute',
    'ping: server_time is the current time');

SELECT * FROM finish();
ROLLBACK;
