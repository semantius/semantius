-- Test get_userinfo() for the first user (auto-admin) scenario.
--
-- The bootstrap grants Administrator (role 2) to the first principal that
-- actually reaches the system, so a fresh install is administrable without a
-- back door. The gate is "no user holds role 2 yet", taken under an advisory
-- lock, plus "this row arrives with last_seen set".
--
-- The cheaper-looking gate, "no other user has last_seen", answers a different
-- question: pre-provisioned users keep last_seen NULL forever, so on a system
-- whose administrator was pre-provisioned - or whose last_seen was cleared - it
-- reads true even though an administrator exists, and elects the next principal
-- to log in on top of them. TEST 19 to 21 build exactly that state and assert
-- the election does not happen; they are what separates the two gates.
--
-- Nothing here is persisted: the whole file runs in one transaction that rolls
-- back, including the deletion of the seeded administrator's role row.
BEGIN;

SELECT plan(22);

-- =====================================================
-- SETUP: Simulate a fresh system with no administrator
-- =====================================================
-- As the installer, so RLS is out of the way and no seeded identity has to hold
-- a permission for the setup to work. Clearing last_seen alone is not enough
-- any more: user3 holds role 2 from the seed, and that is now what the gate
-- reads.

RESET ROLE;
UPDATE users SET last_seen = NULL;
DELETE FROM user_roles WHERE role_id = 2;

-- Test 1: the precondition, so nothing below can pass vacuously
SELECT is(
    (SELECT count(*)::integer FROM user_roles WHERE role_id = 2),
    0,
    'setup: no principal holds Administrator'
);

-- Set JWT claims for a brand-new user
-- (authenticate_as requires the user to already exist, but we need get_userinfo
-- to create them). The role claim is set here rather than inherited from an
-- earlier authenticate_as: rbac.uid() rejects the session without it, and this
-- file authenticates nobody before the first login it is testing.
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'firstuser_ui', true);
SELECT set_config('request.jwt.claim.email', 'firstadmin@test.com', true);
SELECT set_config('request.jwt.claim.name', 'First Admin', true);
SELECT set_config('request.jwt.claim.given_name', 'First', true);
SELECT set_config('request.jwt.claim.family_name', 'Admin', true);

-- Clear any cached context from previous authenticate_as call
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);
SELECT set_config('app.oauth_scopes', NULL, false);

-- Switch to the application role (simulating a real API request)
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- =====================================================
-- TEST: Call get_userinfo() as a brand-new first user
-- Store result once to test the actual first-call behavior
-- =====================================================

CREATE TEMP TABLE first_user_info AS
SELECT public.get_userinfo() AS info;

-- Test 2: get_userinfo() should succeed and return non-null
SELECT ok(
    (SELECT info IS NOT NULL FROM first_user_info),
    'get_userinfo() should succeed for a brand-new first user'
);

-- Test 3: Should have correct email
SELECT is(
    (SELECT info->>'email' FROM first_user_info),
    'firstadmin@test.com',
    'First user should have correct email'
);

-- Test 4: Should have correct display_name from JWT name
SELECT is(
    (SELECT info->>'display_name' FROM first_user_info),
    'First Admin',
    'First user should have display_name from JWT name'
);

-- Test 5: Should have correct first_name from JWT given_name
SELECT is(
    (SELECT info->>'first_name' FROM first_user_info),
    'First',
    'First user should have first_name from JWT given_name'
);

-- Test 6: Should have correct last_name from JWT family_name
SELECT is(
    (SELECT info->>'last_name' FROM first_user_info),
    'Admin',
    'First user should have last_name from JWT family_name'
);

-- Test 7: Should have User role
SELECT ok(
    (SELECT info->'roles' @> '[{"role_name": "User"}]'::jsonb FROM first_user_info),
    'First user should have User role'
);

-- Test 8: Should have Administrator role (auto-assigned as first user)
SELECT ok(
    (SELECT info->'roles' @> '[{"role_name": "Administrator"}]'::jsonb FROM first_user_info),
    'First user should have Administrator role (auto-assigned)'
);

-- Test 9: Should have admin permission
SELECT ok(
    (SELECT info->'permissions' @> '["admin"]'::jsonb FROM first_user_info),
    'First user should have admin permission'
);

-- Test 10: Should have user:read permission
SELECT ok(
    (SELECT info->'permissions' @> '["user:read"]'::jsonb FROM first_user_info),
    'First user should have user:read permission'
);

-- Test 11: Should have user:manage permission
SELECT ok(
    (SELECT info->'permissions' @> '["user:manage"]'::jsonb FROM first_user_info),
    'First user should have user:manage permission'
);

-- Test 12: Modules should NOT be empty
SELECT ok(
    (SELECT jsonb_array_length(info->'modules') > 0 FROM first_user_info),
    'First user (admin) modules should not be empty'
);

-- Test 13: Should see at least _core and Northwind modules (ignoring any additional modules)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}, {"module_name": "Northwind"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core and Northwind modules'
);

-- Test 14: Should see _core module (requires admin permission)
SELECT ok(
    (SELECT info->'modules' @> '[{"module_name": "_core"}]'::jsonb FROM first_user_info),
    'First user (admin) should see _core module'
);

-- =====================================================
-- TEST: bootstrap negatives - the role is taken, so nobody else gets it
-- =====================================================
-- Insert as firstuser_ui, which now holds user:manage. Its own last_seen is
-- irrelevant to its permissions.
RESET ROLE;
SELECT authenticate_as('firstuser_ui');

-- Test 15/16: a second user created WITH last_seen gets role 1 but NOT role 2
INSERT INTO users (id, external_id, email, last_seen)
VALUES (9902, 'seconduser', 'second@test.com', CURRENT_TIMESTAMP);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to second user'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to second user'
);

-- Test 17/18: a user created WITHOUT last_seen gets role 1 but NOT role 2
INSERT INTO users (id, external_id, email, last_seen)
VALUES (9903, 'thirduser', 'third@test.com', NULL);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 1) = 1,
    'Role 1 (User) should be assigned to user without last_seen'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to user without last_seen'
);

-- =====================================================
-- TEST: the state the old gate got wrong
-- =====================================================
-- An administrator exists, and NOT ONE user in the table has a last_seen. That
-- is an ordinary state: every principal was pre-provisioned, or the column was
-- cleared. The old gate read "no other user has last_seen" as "nobody has ever
-- arrived" and elected the next principal to log in, handing Administrator to
-- whoever authenticated next.

RESET ROLE;
UPDATE users SET last_seen = NULL;

-- Test 19: the precondition
SELECT ok(
    (SELECT count(*) FROM user_roles WHERE role_id = 2) > 0
    AND NOT EXISTS (SELECT 1 FROM users WHERE last_seen IS NOT NULL),
    'setup: an administrator exists and no user has ever been seen'
);

SELECT set_config('request.jwt.claim.sub', 'seconduser_ui', true);
SELECT set_config('request.jwt.claim.email', 'second@test.com', true);
SELECT set_config('request.jwt.claim.name', '', true);
SELECT set_config('request.jwt.claim.given_name', '', true);
SELECT set_config('request.jwt.claim.family_name', '', true);
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

CREATE TEMP TABLE second_user_info AS
SELECT public.get_userinfo() AS info;

-- Test 20/21
SELECT ok(
    (SELECT info->'roles' @> '[{"role_name": "User"}]'::jsonb FROM second_user_info),
    'a principal provisioned while an administrator exists still gets the User role'
);

SELECT ok(
    (SELECT NOT (info->'roles' @> '[{"role_name": "Administrator"}]'::jsonb) FROM second_user_info),
    'a principal provisioned while an administrator exists is NOT elected, even though no user has last_seen'
);

-- =====================================================
-- TEST: an empty administrator set elects again
-- =====================================================
-- rbac.assert_administrator_remains refuses to leave the set empty, so reaching
-- this state needs the BYPASSRLS exemption - a direct superuser connection,
-- which is what RESET ROLE gives here. It is worth pinning anyway, because it is
-- what an operator repairing a database by hand will hit, and because it is the
-- difference between this gate and a one-shot marker: there is no reset path and
-- no marker row to clear.
--
-- Note the subject. The election is on INSERT, so it reaches a principal that
-- has no users row yet; an established principal logging in again goes through
-- ON CONFLICT DO UPDATE and is never elected, which is why the set is guarded
-- rather than left to recover on its own.

RESET ROLE;
DELETE FROM user_roles WHERE role_id = 2;

SELECT set_config('request.jwt.claim.sub', 'thirduser_ui', true);
SELECT set_config('request.jwt.claim.email', 'third_ui@test.com', true);
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);

SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

-- Test 22
SELECT ok(
    (SELECT public.get_userinfo()->'roles' @> '[{"role_name": "Administrator"}]'::jsonb),
    'with the administrator set empty, a principal arriving for the first time is elected'
);

SELECT * FROM finish();
ROLLBACK;
