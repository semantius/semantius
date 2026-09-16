-- =====================================================
-- rbac.uid() claim-normalization paths (0410)
-- =====================================================
-- authenticate_as() always sets Neon-style request.jwt.claim.* settings, so
-- the suite never exercised the Supabase-style single JSON blob path of
-- rbac.uid() (0030_rbac_functions.sql, "Step 2") nor the JSON-scalar audience
-- form, nor the `roles`-array stand-in for a missing `role` claim ("Step 3").
-- 0250 covers plain-string and JSON-array audiences, 0390 covers the no-claims
-- session. This file fills the remaining branches.
--
-- Every group starts from a semantius_user session whose Neon-style role/sub
-- settings are blank, so rbac.uid() has to fall back to request.jwt.claims.
-- All settings are transaction-local and vanish with the ROLLBACK.
BEGIN;

SELECT plan(22);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- Helper: blank the Neon-style settings so the blob path is taken again
-- (rbac.uid() fans the blob out into them on success).
CREATE FUNCTION pg_temp.blank_neon_claims() RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.role', '', true);
    SELECT set_config('request.jwt.claim.sub', '', true);
    SELECT set_config('request.jwt.claim.email', '', true);
    SELECT set_config('request.jwt.claim.aud', '', true);
$$;

-- =====================================================
-- GROUP 1: a valid Supabase-style blob is accepted and normalized
-- =====================================================
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","role":"authenticated","email":"sales@test.com","iss":"https://issuer.example"}', true);

SELECT is(rbac.uid(), 'user2', 'uid: the sub of a request.jwt.claims blob is returned');
SELECT is(current_setting('request.jwt.claim.sub', true), 'user2',
    'uid: the blob sub is fanned out into request.jwt.claim.sub');
SELECT is(current_setting('request.jwt.claim.role', true), 'authenticated',
    'uid: the blob role is fanned out into request.jwt.claim.role');
SELECT is(current_setting('request.jwt.claim.email', true), 'sales@test.com',
    'uid: other blob claims are fanned out too');
SELECT is(current_setting('request.jwt.claim.iss', true), 'https://issuer.example',
    'uid: arbitrary blob claims become request.jwt.claim.<key> settings');
SELECT is(rbac.uid(), 'user2', 'uid: the normalized Neon-style settings are used on the next call');

-- =====================================================
-- GROUP 2: invalid blobs are rejected with insufficient_privilege
-- =====================================================
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"sub":"user2","role":"anon"}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a blob whose role is not authenticated is rejected');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"role":"authenticated","email":"x@test.com"}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a blob without a sub is rejected');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"sub":"","role":"authenticated"}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a blob with an empty sub is rejected');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', 'this is not json', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a blob that is not valid JSON is rejected (not a JSON parse error)');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: an empty blob is rejected');

-- =====================================================
-- GROUP 3: a `roles` array stands in for a missing `role` claim
-- =====================================================
-- The Microsoft Entra ID shape. `role` and `roles` are both restricted claims
-- there, so an app role named `authenticated` is the only way the issuer can
-- say it, and it arrives as an array. PostgREST reads the same array to pick
-- the database role (jwt-role-claim-key = `.roles[0]`).
-- Runs BEFORE the audience group on purpose: that group inserts a jwt_aud row
-- which would then apply to every call here too.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","roles":["authenticated"],"email":"sales@test.com"}', true);
SELECT is(rbac.uid(), 'user2', 'uid: a roles array carrying authenticated is accepted when role is absent');
SELECT is(current_setting('request.jwt.claim.role', true), 'authenticated',
    'uid: the verdict is cached as request.jwt.claim.role for the next call');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","roles":["reader","authenticated","admin"]}', true);
SELECT is(rbac.uid(), 'user2', 'uid: authenticated is found among several roles');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"sub":"user2","roles":["reader","admin"]}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a roles array without authenticated is rejected');

-- Issuers that emit `roles` as a string rather than an array.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"sub":"user2","roles":"authenticated"}', true);
SELECT is(rbac.uid(), 'user2', 'uid: a roles claim holding a single JSON string is accepted');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"sub":"user2","roles":"reader authenticated"}', true);
SELECT is(rbac.uid(), 'user2', 'uid: a space-separated roles string is accepted');

-- An explicit role claim still decides, whatever roles says.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","role":"anon","roles":["authenticated"]}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: role=anon is still refused even when roles carries authenticated');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims', '{"roles":["authenticated"]}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a roles array without a sub is rejected');

-- =====================================================
-- GROUP 4: JSON-scalar audience (jwt_aud configured in _settings)
-- =====================================================
RESET ROLE;
INSERT INTO _settings (name, value) VALUES ('jwt_aud', 'myapp');
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'user1', true);

SELECT set_config('request.jwt.claim.aud', '"myapp"', true);
SELECT lives_ok($$SELECT rbac.uid()$$,
    'uid: a JSON string audience equal to jwt_aud is accepted');

SELECT set_config('request.jwt.claim.aud', '"otherapp"', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a JSON string audience that differs from jwt_aud is rejected');

SELECT set_config('request.jwt.claim.aud', '', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: a missing audience is rejected when jwt_aud is configured');

SELECT * FROM finish();
ROLLBACK;
