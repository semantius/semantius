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
-- Scope format: there is one rule now. Every
-- reader of app.oauth_scopes - has_permission, has_any_permission and
-- user_has_permission - and validate_oauth_scopes' request parameter split on
-- any run of commas or whitespace, so "a,b", "a b" and " a ,, b " are the same
-- two scopes. Before that, has_permission and has_any_permission read commas
-- while user_has_permission read spaces, and a list in the "wrong" format
-- silently confined the session to nothing. GROUP 6 pins the agreement.
-- Normalizing separators does not make the confinement binding, and this file
-- does not pretend otherwise. app.oauth_scopes is client-settable, so a session
-- that can run SQL can blank it and walk out of its own confinement - and a
-- blank list reads as "no scopes", i.e. no restriction. Closing that needs the
-- scope list carried in a context the client cannot forge, written and
-- checksummed by a definer-only entry point. Not done; not tested here.
BEGIN;

SELECT plan(58);

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
-- GROUP 6: separator normalization
-- =====================================================
-- Two scopes, written three ways: space-separated, comma-separated, and with
-- mixed and repeated separators. Every reader must give the same answer to each,
-- and it must be the permissive one: user2 holds both nwind:view and
-- nwind:manage, so a scope list naming both takes nothing away.
--
-- Five of these assertions fail against the pre-normalization readers: the space
-- and mixed forms made has_permission and has_any_permission deny everything
-- (they split on commas), and the comma form made user_has_permission deny
-- everything (it split on spaces). The mixed form happened to survive the old
-- user_has_permission, because splitting it on spaces still yielded the scope.
SELECT set_config('app.oauth_scopes', '', true);
SELECT authenticate_as('user3');   -- admin, so user_has_permission is allowed

SELECT set_config('app.oauth_scopes', 'nwind:view nwind:manage', true);
SELECT ok(rbac.user_has_permission('user2', 'nwind:manage'),
    'space-separated scopes: user_has_permission agrees');
SELECT set_config('app.oauth_scopes', 'nwind:view,nwind:manage', true);
SELECT ok(rbac.user_has_permission('user2', 'nwind:manage'),
    'comma-separated scopes: user_has_permission agrees');
SELECT set_config('app.oauth_scopes', ' nwind:view , , nwind:manage ', true);
SELECT ok(rbac.user_has_permission('user2', 'nwind:manage'),
    'mixed and repeated separators: user_has_permission agrees');

-- Negative control: normalization must not invent a scope that is not listed.
SELECT set_config('app.oauth_scopes', 'nwind:view nwind:manage', true);
SELECT ok(NOT rbac.user_has_permission('user3', 'admin'),
    'normalized scopes still confine: admin is not in the list');

SELECT set_config('app.oauth_scopes', '', true);   -- authenticate_as reads
SELECT authenticate_as('user2');                   -- users under RLS first

SELECT set_config('app.oauth_scopes', 'nwind:view nwind:manage', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'space-separated scopes: has_permission agrees');
SELECT ok(rbac.has_any_permission('admin', 'nwind:manage'),
    'space-separated scopes: has_any_permission agrees');
SELECT set_config('app.oauth_scopes', 'nwind:view,nwind:manage', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'comma-separated scopes: has_permission agrees');
SELECT ok(rbac.has_any_permission('admin', 'nwind:manage'),
    'comma-separated scopes: has_any_permission agrees');
SELECT set_config('app.oauth_scopes', ' nwind:view , , nwind:manage ', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'mixed and repeated separators: has_permission agrees');

-- Negative control: a scope list that omits the permission still denies it.
SELECT set_config('app.oauth_scopes', 'nwind:view', true);
SELECT ok(NOT rbac.has_permission('nwind:manage'),
    'normalized scopes still confine: nwind:manage is not in the list');


-- Whitespace that is not a space. These exist because the normalization was
-- once written as btrim(scopes, E', <TAB><CR><LF>') with those three characters
-- typed literally into the source rather than escaped. The migrations are CRLF
-- in the repository and the generated extension script is LF, so that literal
-- compiled to a DIFFERENT character set on the two install paths - and both
-- suites passed, because nothing fed a tab or a carriage return. The trim is
-- gone now, but the hazard is structural: 129 of 260 function bodies carry
-- carriage returns on the migrate path and none do on the extension path, so
-- any character set typed into a migration means two things. These assertions
-- are the tripwire for the scope readers.
SELECT set_config('app.oauth_scopes', E'nwind:view\tnwind:manage', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'tab-separated scopes: has_permission agrees');
SELECT set_config('app.oauth_scopes', E'nwind:view\r\nnwind:manage', true);
SELECT ok(rbac.has_permission('nwind:manage'),
    'CRLF-separated scopes: has_permission agrees');
SELECT set_config('app.oauth_scopes', E'nwind:view\r', true);
SELECT ok(rbac.has_permission('nwind:view'),
    'a trailing carriage return does not hide the scope it follows');

-- Fails closed: a value made only of separators is not "no confinement".
SELECT set_config('app.oauth_scopes', ' , ', true);
SELECT ok(NOT rbac.has_permission('nwind:view'),
    'a separator-only scope list denies rather than granting');
SELECT set_config('app.oauth_scopes', '', true);

-- validate_oauth_scopes takes the request as a parameter, not from the GUC.
SELECT set_config('app.oauth_scopes', '', true);
SELECT authenticate_as('user3');
SELECT set_config('app.oauth_scopes', '', true);
SELECT results_eq(
    $$SELECT scope, is_valid FROM rbac.validate_oauth_scopes('user2', 'nwind:view,admin') ORDER BY scope$$,
    $$VALUES ('admin'::text, false), ('nwind:view'::text, true)$$,
    'validate_oauth_scopes: a comma-separated request is split the same way as a space-separated one');

-- This is the assertion that would have caught the two install paths compiling
-- different trim sets: with the old btrim, the trailing carriage return was
-- stripped on the CRLF migrate path and survived on the LF extension build,
-- where it split off a second, empty scope row.
SELECT is((SELECT count(*)::int FROM rbac.validate_oauth_scopes('user2', E'nwind:view\r')),
    1, 'validate_oauth_scopes: a trailing carriage return yields no extra empty scope');
SELECT is((SELECT count(*)::int FROM rbac.validate_oauth_scopes('user2', ' , ')),
    0, 'validate_oauth_scopes: a separator-only request yields no rows');

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
