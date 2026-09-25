-- The system must always keep an enabled Administrator (0091)
-- =====================================================
-- With no enabled holder of role 2 there is no way back in through the API:
-- granting a role, enabling a user and creating a user all require `admin`, and
-- the first-user election fires on INSERT only, so an existing principal is
-- never elected however many times it logs in. rbac.assert_administrator_remains
-- refuses the three statements that reach that state.
--
-- Fixture: the seeded identities. user3 (1003) is the only Administrator, which
-- is what makes every "last one" case below the real one. A direct superuser
-- connection is exempt, so each case is asserted as user3 over the request role,
-- and the exemption itself is asserted with RESET ROLE.
BEGIN;

SELECT plan(16);

SELECT authenticate_as('user3');

-- Precondition, so nothing below passes vacuously.
SELECT is(
    (SELECT count(*)::integer FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE ur.role_id = 2 AND u.is_disabled = FALSE),
    1,
    'user3 is the only enabled Administrator');

-- =====================================================
-- The three routes to an unadministrable system
-- =====================================================

SELECT throws_ok(
    $$DELETE FROM user_roles WHERE user_id = 1003 AND role_id = 2$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'removing the role from the last Administrator is refused');

SELECT throws_ok(
    $$DELETE FROM users WHERE id = 1003$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'deleting the last Administrator is refused, cascade included');

SELECT throws_ok(
    $$UPDATE users SET is_disabled = TRUE WHERE id = 1003$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'disabling the last Administrator is refused');

-- A set-wide delete is the same statement in a wider shape, and the check runs
-- once at the end, so it cannot be walked past one row at a time.
SELECT throws_ok(
    $$DELETE FROM user_roles WHERE role_id = 2$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'deleting every Administrator row at once is refused');

-- Deleting the role itself cascades into user_roles and is caught the same way.
-- Two guards stand in front of it and the first is not this one: modules
-- reference role 2 as their default_admin_role_id, so the FK refuses the delete
-- with 23503 before any trigger runs. Clearing that reference is what makes the
-- cascade reachable, and it is the state a module deletion would leave behind.
SELECT throws_ok(
    $$DELETE FROM roles WHERE id = 2$$,
    '23503',
    NULL,
    'a module referencing the Administrator role blocks the delete on its own');

UPDATE modules SET default_admin_role_id = NULL WHERE default_admin_role_id = 2;

SELECT throws_ok(
    $$DELETE FROM roles WHERE id = 2$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'with the reference gone, the guard refuses the delete that would cascade');

-- =====================================================
-- The guard does not rest on who the caller is
-- =====================================================
-- Writing users needs `user:manage`, not `admin`: users_insert_policy,
-- users_update_policy and users_delete_policy all name it. A guard that excused
-- every caller without `admin` would excuse exactly the callers who can empty
-- the Administrator set without being one, which is why the count runs through
-- rbac.count_enabled_administrators instead of asking what the caller is.
-- granted_by is pinned to user1 rather than left to default to the granting
-- administrator. user_permissions.granted_by references users(id) with no ON
-- DELETE action, so a row pointing at user3 would make the delete below fail on
-- 23503 before the guard ever ran, and the guard is what is under test here.
INSERT INTO user_permissions (user_id, permission_name, granted_by)
VALUES (1001, 'user:manage', 1001);

SELECT authenticate_as('user1');

SELECT throws_ok(
    $$UPDATE users SET is_disabled = TRUE WHERE id = 1003$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'user:manage without admin cannot disable the last Administrator');

SELECT throws_ok(
    $$DELETE FROM users WHERE id = 1003$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'user:manage without admin cannot delete the last Administrator');

-- The other half of counting through a definer. A statement trigger fires even
-- when RLS reduced the statement to no rows, and user2 may read neither
-- user_roles nor another user's row - so the count cannot come from the
-- caller's view, which would read as zero here. The true count is unchanged and
-- not zero, so a statement that did nothing is refused nothing.
SELECT authenticate_as('user2');

SELECT lives_ok(
    $$DELETE FROM users WHERE id = 1003$$,
    'a statement that RLS reduces to no rows is not refused');

SELECT authenticate_as('user3');

-- =====================================================
-- What the guard does not block
-- =====================================================
-- It is a floor, not a lock: with a second Administrator in place every one of
-- those statements is ordinary again.

INSERT INTO user_roles (user_id, role_id) VALUES (1001, 2);

SELECT lives_ok(
    $$DELETE FROM user_roles WHERE user_id = 1003 AND role_id = 2$$,
    'the role can be removed once another Administrator holds it');

SELECT is(
    (SELECT count(*)::integer FROM user_roles WHERE role_id = 2),
    1,
    'user1 is now the only Administrator');

-- The floor moves with it: user1 is the last one now.
SELECT throws_ok(
    $$DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'the guard follows the last remaining holder, whoever that is');

-- A disabled holder does not count. user3 keeps role 2 here but is disabled, so
-- user1 is still the only enabled Administrator and still cannot be removed.
-- This is the case a plain "does anybody hold role 2" check would get wrong.
INSERT INTO user_roles (user_id, role_id) VALUES (1003, 2);
UPDATE users SET is_disabled = TRUE WHERE id = 1003;

SELECT throws_ok(
    $$DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2$$,
    '42501',
    'This would leave the system without an enabled Administrator',
    'a disabled holder of the role does not satisfy the guard');

-- Ordinary user writes are untouched: the disable trigger is scoped to the
-- is_disabled column, so a login refreshing last_seen never runs the check.
SELECT lives_ok(
    $$UPDATE users SET last_seen = CURRENT_TIMESTAMP WHERE id = 1002$$,
    'an ordinary user update is not affected by the guard');

-- =====================================================
-- The operator escape hatch
-- =====================================================
-- A direct superuser or owner connection is exempt, which is how a database is
-- repaired and how 0110_test_first_user_get_userinfo.sql builds a system that
-- has never had an Administrator.
RESET ROLE;

SELECT lives_ok(
    $$DELETE FROM user_roles WHERE role_id = 2$$,
    'a BYPASSRLS connection may still empty the Administrator set');

SELECT * FROM finish();
ROLLBACK;
