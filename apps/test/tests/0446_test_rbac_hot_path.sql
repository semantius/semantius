-- =====================================================
-- RBAC warm-path permission checks (0446)
-- =====================================================
-- A warm permission check used to enter two PL/pgSQL frames and
-- resolve the caller's identity twice: rbac.has_permission called rbac.uid(),
-- then rbac.ensure_context_initialized(), which called rbac.uid() again before
-- reaching its "already initialized" shortcut. The shortcut therefore sat
-- behind all of the work it was meant to skip. The cache test is now inlined
-- into the checkers, so a warm check enters one frame and calls neither.
--
-- Two properties have to survive that, and this file pins both.
--
-- 1. ORDERING. Each checker now carries its own copy of the bearer-session
--    test, and every copy must stay ahead of the cache read. The app.* settings
--    are ordinary GUCs that whoever holds the session can overwrite, and no
--    checker can tell a value written by rbac from one written by the client.
--    Behind PostgREST or an app server that is harmless, because the client
--    never runs SQL. A PostgreSQL 18 OAuth bearer session does run SQL as the
--    request role, so there the cache is not trusted at any point. A copy that
--    read the cache before testing for a bearer session would silently trust a
--    forged context in exactly that case.
--    pgTAP cannot open a bearer session (system_user cannot be faked), so the
--    ordering is asserted structurally here and exercised for real by
--    `pgdocker/test_bearer_cache.ts`.
--
-- 2. NO NEW WAY IN. The removed rbac.uid() calls had a side effect: they
--    refused a session carrying no valid claims at all. The warm path now
--    compares app.current_external_id with request.jwt.claim.sub, which keeps
--    that refusal. This is NOT a fix for the client-writable cache and is
--    not needed in a supported deployment - behind PostgREST or an app server
--    the client never runs SQL and cannot write app.* in the first place.
--
-- The speed itself is measured, not asserted: call counting needs
-- track_functions, which is superuser-only, and the suite runs against
-- whatever DATABASE_URL names.
BEGIN;

SELECT plan(16);

-- =====================================================
-- GROUP 1: structure - the inlined test, and its ordering
-- =====================================================
-- These are the assertions that fail if the change is reverted: before it,
-- neither checker mentioned app.context_initialized at all.
SELECT ok(strpos(p.prosrc, 'app.context_initialized') > 0,
    'has_permission: reads the context cache itself, rather than only delegating')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rbac' AND p.proname = 'has_permission';

SELECT ok(strpos(p.prosrc, 'app.context_initialized') > 0,
    'has_any_permission: tests the context cache itself')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rbac' AND p.proname = 'has_any_permission';

-- The `> 0` half is required: strpos returns 0 when the needle is absent,
-- which would satisfy `<` vacuously and let a checker with no bearer test pass.
SELECT ok(strpos(p.prosrc, 'oauth:%') > 0
      AND strpos(p.prosrc, 'oauth:%') < strpos(p.prosrc, 'app.context_initialized'),
    'has_permission: the bearer test precedes the cache read')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rbac' AND p.proname = 'has_permission';

SELECT ok(strpos(p.prosrc, 'oauth:%') > 0
      AND strpos(p.prosrc, 'oauth:%') < strpos(p.prosrc, 'app.context_initialized'),
    'has_any_permission: the bearer test precedes the cache read')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rbac' AND p.proname = 'has_any_permission';

SELECT ok(strpos(p.prosrc, 'oauth:%') > 0
      AND strpos(p.prosrc, 'oauth:%') < strpos(p.prosrc, 'app.context_initialized'),
    'ensure_context_initialized: the bearer test precedes the cache read')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'rbac' AND p.proname = 'ensure_context_initialized';

-- The helper is no longer called on the hot path but must still exist: whoami
-- reports through it and 0435 pins its result.
SELECT is(rbac.is_bearer_session(), false,
    'is_bearer_session: still present and false in a SCRAM session');

-- =====================================================
-- GROUP 2: a genuine warm cache is used (positive controls)
-- =====================================================
SELECT authenticate_as('user2');
SELECT rbac.has_permission('nwind:view');   -- cold pass populates the cache

SELECT is(rbac.has_permission('nwind:view'), true,
    'warm hit: has_permission returns the held permission');
SELECT is(rbac.has_any_permission('nwind:view', 'admin'), true,
    'warm hit: has_any_permission returns the held permission');

-- The two assertions above would pass just as well if every call rebuilt the
-- context from scratch, so they do not show the cache is used. These do: user2
-- does not hold admin and a rebuild would never produce it, so a TRUE answer can
-- only have come from the cached string. The subject is left untouched, which is
-- what separates this from the forged cache in GROUP 3 - same tampering, but
-- consistent with the session's own claims, so the warm path accepts it.
SELECT set_config('app.user_permissions', 'admin,nwind:view', true);
SELECT is(rbac.has_permission('admin'), true,
    'warm hit: has_permission answers from the cache, not from a rebuild');
SELECT is(rbac.has_any_permission('admin'), true,
    'warm hit: has_any_permission answers from the cache, not from a rebuild');
SELECT isnt(nullif(current_setting('app.current_user_id', true), ''), NULL,
    'app.current_user_id is populated whenever app.context_initialized is true');

-- =====================================================
-- GROUP 3: a hand-written cache naming another subject is not used
-- =====================================================
-- user2 keeps its own valid claims and rewrites the cache to claim user3's
-- identity and the admin permission. Before this change both checkers returned
-- TRUE here, because the shortcut only asked whether the cache existed.
SELECT set_config('app.user_permissions',    'admin', true);
SELECT set_config('app.context_initialized', 'true',  true);
SELECT set_config('app.current_external_id', 'user3', true);

SELECT is(rbac.has_permission('admin'), false,
    'forged cache: has_permission rebuilds and denies a permission user2 lacks');
SELECT is(rbac.has_any_permission('admin'), false,
    'forged cache: has_any_permission rebuilds and denies it too');

-- =====================================================
-- GROUP 4: no claims at all is still refused
-- =====================================================
-- The property the removed rbac.uid() calls used to provide.
RESET ROLE;
SET ROLE semantius_user;
SELECT set_config('request.jwt.claim.sub',  '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('app.user_permissions',    'admin', true);
SELECT set_config('app.context_initialized', 'true',  true);
SELECT set_config('app.current_external_id', 'user3', true);

SELECT throws_ok(
    $$ SELECT rbac.has_permission('admin') $$,
    '42501', NULL,
    'no claims: a hand-written warm cache does not authenticate the session');

SELECT throws_ok(
    $$ SELECT rbac.has_permission('') $$,
    '42501', NULL,
    'no claims: a blank permission name still raises rather than returning FALSE');

-- Positive control for the assertion above: the blank name itself is what
-- returns FALSE, once the session is authenticated.
RESET ROLE;
SELECT authenticate_as('user2');
SELECT is(rbac.has_permission('  '), false,
    'authenticated: a blank permission name returns FALSE');

SELECT * FROM finish();
ROLLBACK;
