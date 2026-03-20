-- Test JWT audience (aud) claim validation via _settings.jwt_aud
BEGIN;

SELECT plan(5);

-- =====================================================
-- TEST a) No jwt_aud entry in _settings → auth works normally
-- =====================================================

SELECT authenticate_as('user1');

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when no jwt_aud setting is present'
);

-- =====================================================
-- Setup: insert jwt_aud into _settings (requires superuser / BYPASSRLS),
-- then switch back to semantius_user manually so that subsequent SET ROLE
-- calls don't trigger the users-table RLS before the aud claim is set.
-- =====================================================

RESET ROLE;
INSERT INTO _settings (name, value) VALUES ('jwt_aud', 'myapp');
-- Restore the semantius_user role and search_path (JWT claims from the
-- previous authenticate_as call are still in effect via SET LOCAL).
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- =====================================================
-- TEST b) aud matches single plain-string value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', 'myapp', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when aud matches the required single value'
);

-- =====================================================
-- TEST c) aud is a JSON array and contains the required value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', '["myapp","other"]', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT lives_ok(
    $$ SELECT rbac.uid() $$,
    'uid() succeeds when aud array contains the required value'
);

-- =====================================================
-- TEST d) aud is a plain string that does NOT match
-- =====================================================

SELECT set_config('request.jwt.claim.aud', 'wrongapp', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT throws_ok(
    $$ SELECT rbac.uid() $$,
    '42501',
    NULL,
    'uid() fails when aud single value does not match'
);

-- =====================================================
-- TEST e) aud is a JSON array with no matching value
-- =====================================================

SELECT set_config('request.jwt.claim.aud', '["wrongapp","notmyapp"]', true);
SELECT set_config('app.context_initialized', NULL, false);

SELECT throws_ok(
    $$ SELECT rbac.uid() $$,
    '42501',
    NULL,
    'uid() fails when none of the aud array values match'
);

SELECT * FROM finish();
ROLLBACK;
