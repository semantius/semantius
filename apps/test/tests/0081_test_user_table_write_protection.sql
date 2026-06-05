-- Verify that a regular (non-admin) user cannot write the users table directly.
--
-- Only admins (the `user:manage` permission) may INSERT/UPDATE/DELETE users via
-- RLS (see 0050_rbac_rls.sql). First-login provisioning happens through the
-- SECURITY DEFINER rbac.upsert_user_from_jwt(), which bypasses RLS but only ever
-- touches the caller's OWN row. A regular user must NOT be able to change any
-- user row (their own or someone else's) by writing the table directly.
BEGIN;

SELECT plan(5);

-- user1 is a regular user (no user:manage).
SELECT authenticate_as('user1');

-- 1. INSERT is rejected by the RLS WITH CHECK (insufficient_privilege).
SELECT throws_ok(
    $$ INSERT INTO users (external_id, email) VALUES ('attacker_injected', 'evil@example.com') $$,
    '42501',
    NULL,
    'regular user cannot INSERT into users (RLS WITH CHECK)'
);

-- 2. UPDATE of another user's email is a silent no-op: RLS USING hides the row,
--    so zero rows are affected (and nothing changes).
WITH upd AS (
    UPDATE users SET email = 'hacked@evil.com' WHERE external_id = 'user2' RETURNING 1
)
SELECT is( count(*)::int, 0,
    'regular user UPDATE of another user affects 0 rows' ) FROM upd;

-- 3. DELETE is likewise a no-op for a regular user.
WITH del AS (
    DELETE FROM users WHERE external_id = 'user2' RETURNING 1
)
SELECT is( count(*)::int, 0,
    'regular user DELETE on users affects 0 rows' ) FROM del;

-- 4. Confirm (as an admin) the attacked row was untouched.
SELECT authenticate_as('user3');  -- admin: has user:manage / user:read
SELECT isnt(
    (SELECT email FROM users WHERE external_id = 'user2'),
    'hacked@evil.com',
    'user2 email is unchanged after the regular-user write attempts'
);

-- 5. Positive control: an admin CAN update users.
WITH upd AS (
    UPDATE users SET email = email WHERE external_id = 'user2' RETURNING 1
)
SELECT is( count(*)::int, 1,
    'admin (user:manage) can UPDATE users' ) FROM upd;

SELECT * FROM finish();
ROLLBACK;
