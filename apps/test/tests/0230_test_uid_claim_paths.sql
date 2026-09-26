-- =====================================================
-- rbac.uid() claim-normalization paths (0230)
-- =====================================================
-- authenticate_as() always sets Neon-style request.jwt.claim.* settings, so
-- the suite never exercised the Supabase-style single JSON blob path of
-- rbac.uid() (0080_rbac_functions.sql, "Step 2") nor the JSON-scalar audience
-- form, nor the `roles`-array stand-in for a missing `role` claim ("Step 3"),
-- nor the entra.<tid>.<oid> subject of a Microsoft Entra ID token ("Step 4").
-- 0240 covers plain-string and JSON-array audiences, 0270 covers the no-claims
-- session. This file fills the remaining branches.
--
-- Every group starts from a semantius_user session whose Neon-style role/sub
-- settings are blank, so rbac.uid() has to fall back to request.jwt.claims.
-- All settings are transaction-local and vanish with the ROLLBACK.
BEGIN;

SELECT plan(33);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- Helper: blank the Neon-style settings so the blob path is taken again
-- (rbac.uid() fans the blob out into them on success).
CREATE FUNCTION pg_temp.blank_neon_claims() RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.role', '', true);
    SELECT set_config('request.jwt.claim.sub', '', true);
    SELECT set_config('request.jwt.claim.email', '', true);
    SELECT set_config('request.jwt.claim.aud', '', true);
    SELECT set_config('request.jwt.claim.iss', '', true);
    SELECT set_config('request.jwt.claim.tid', '', true);
    SELECT set_config('request.jwt.claim.oid', '', true);
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
-- GROUP 4: a Microsoft Entra ID token is identified as entra.<tid>.<oid>
-- =====================================================
-- Entra's sub is pairwise per app registration, so the issuer URL selects the
-- tenant-wide object id instead. Also before the audience group, for the same
-- reason as group 3.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"pairwise-sub-app-a","roles":["authenticated"],'
    '"iss":"https://login.microsoftonline.com/7d0f4c1e-2b1a-4c3e-9f00-0000000000aa/v2.0",'
    '"tid":"7d0f4c1e-2b1a-4c3e-9f00-0000000000aa","oid":"3f9e2d10-8c4b-4a7e-b1d2-0000000000bb"}', true);
SELECT is(rbac.uid(),
    'entra.7d0f4c1e-2b1a-4c3e-9f00-0000000000aa.3f9e2d10-8c4b-4a7e-b1d2-0000000000bb',
    'uid: a v2 Entra token is identified by entra.<tid>.<oid>, not by sub');
SELECT is(current_setting('request.jwt.claim.sub', true),
    'entra.7d0f4c1e-2b1a-4c3e-9f00-0000000000aa.3f9e2d10-8c4b-4a7e-b1d2-0000000000bb',
    'uid: the Entra subject is written back into request.jwt.claim.sub');
SELECT is(rbac.uid(),
    'entra.7d0f4c1e-2b1a-4c3e-9f00-0000000000aa.3f9e2d10-8c4b-4a7e-b1d2-0000000000bb',
    'uid: a second call on the normalized settings yields the same subject');

-- The same person through a second app registration: a different sub, the
-- same tid and oid, and therefore the same user.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"pairwise-sub-app-b","roles":["authenticated"],'
    '"iss":"https://login.microsoftonline.com/7d0f4c1e-2b1a-4c3e-9f00-0000000000aa/v2.0",'
    '"tid":"7d0f4c1e-2b1a-4c3e-9f00-0000000000aa","oid":"3f9e2d10-8c4b-4a7e-b1d2-0000000000bb"}', true);
SELECT is(rbac.uid(),
    'entra.7d0f4c1e-2b1a-4c3e-9f00-0000000000aa.3f9e2d10-8c4b-4a7e-b1d2-0000000000bb',
    'uid: another app registration''s sub for the same person resolves to the same subject');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"x","roles":["authenticated"],"iss":"https://sts.windows.net/tenant-1/",'
    '"tid":"tenant-1","oid":"object-1"}', true);
SELECT is(rbac.uid(), 'entra.tenant-1.object-1', 'uid: a v1 Entra issuer is recognized');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"x","roles":["authenticated"],"iss":"https://tenant-1.ciamlogin.com/tenant-1/v2.0",'
    '"tid":"tenant-1","oid":"object-1"}', true);
SELECT is(rbac.uid(), 'entra.tenant-1.object-1', 'uid: an Entra External ID (CIAM) issuer is recognized');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"x","roles":["authenticated"],"iss":"https://login.microsoftonline.com/tenant-1/v2.0",'
    '"tid":"tenant-1"}', true);
SELECT throws_ok($$SELECT rbac.uid()$$, '42501', NULL,
    'uid: an Entra token without oid is refused rather than falling back to sub');

-- Only the issuer URL selects the Entra identity: other issuers keep sub even
-- when they send claims named tid and oid, and a look-alike host is not Entra.
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","role":"authenticated","iss":"https://issuer.example",'
    '"tid":"tenant-1","oid":"object-1"}', true);
SELECT is(rbac.uid(), 'user2', 'uid: a non-Entra issuer with tid and oid claims keeps its sub');

SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"user2","role":"authenticated",'
    '"iss":"https://login.microsoftonline.com.evil.example/tenant-1/v2.0",'
    '"tid":"tenant-1","oid":"object-1"}', true);
SELECT is(rbac.uid(), 'user2', 'uid: a look-alike Entra host is not treated as Entra');

-- End to end: the warm-path caches compare against request.jwt.claim.sub, so
-- the rewritten subject must find the user and stay warm on the next call.
RESET ROLE;
INSERT INTO users (id, external_id, email)
VALUES (9410, 'entra.tenant-1.object-1', 'entra-user@test.com');
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);
SELECT pg_temp.blank_neon_claims();
SELECT set_config('request.jwt.claims',
    '{"sub":"x","roles":["authenticated"],"iss":"https://login.microsoftonline.com/tenant-1/v2.0",'
    '"tid":"tenant-1","oid":"object-1"}', true);
SELECT is(rbac.user_id(), 9410::bigint, 'user_id: an Entra token finds the user stored as entra.<tid>.<oid>');
SELECT is(current_setting('app.current_external_id', true), 'entra.tenant-1.object-1',
    'user_id: the context caches the Entra subject, which the warm path then matches');

-- =====================================================
-- GROUP 5: JSON-scalar audience (jwt_aud configured in _settings)
-- =====================================================
RESET ROLE;
INSERT INTO _settings (name, value) VALUES ('jwt_aud', 'myapp');
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);
SELECT pg_temp.blank_neon_claims();
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
