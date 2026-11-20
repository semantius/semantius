-- The system must always keep an enabled Administrator (0370)
-- =====================================================
-- With no enabled holder of role 2 there is no way back in through the API:
-- granting a role, enabling a user and creating a user all require `admin`, and
-- the first-user election fires on INSERT only, so an existing principal is
-- never elected however many times it logs in. rbac.assert_administrator_remains
-- and the guards next to it refuse the statements that reach that state.
--
-- Fixture: the seeded identities. user3 (1003) is the only Administrator, which
-- is what makes every "last one" case below the real one. A direct connection
-- as a role with BYPASSRLS is exempt, so each case is asserted as user3 over the
-- request role, and the exemption itself is asserted with RESET ROLE.
BEGIN;

SELECT plan(30);

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
-- reference role 2 as their default_admin_role_id, so the foreign key refuses
-- the delete before any trigger runs. It is ON DELETE RESTRICT, which raises
-- 23001 (restrict_violation) on PostgreSQL 18 and 23503 before, so the message
-- common to both is matched, as in 0550_test_foreign_keys.sql. Clearing that
-- reference is what makes the cascade reachable, and it is the state a module
-- deletion would leave behind.
SELECT throws_like(
    $$DELETE FROM roles WHERE id = 2$$,
    'update or delete on table "roles" violates %foreign key constraint "modules_default_admin_role_id_fkey" on table "modules"',
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
-- A direct connection as a role with BYPASSRLS is exempt, which is how a
-- database is repaired and how 0210_test_first_user_get_userinfo.sql builds a
-- system that has never had an Administrator.
RESET ROLE;

SELECT lives_ok(
    $$DELETE FROM user_roles WHERE role_id = 2$$,
    'a BYPASSRLS connection may still empty the Administrator set');

-- =====================================================
-- The other routes to a system without a working Administrator
-- =====================================================
-- Deleting is not the only way to empty the Administrator set. An UPDATE can
-- point the last Administrator's user_roles row at another role or at a
-- disabled user, and the authority itself can be taken from role 2: by
-- removing or re-pointing its role_permissions row for `admin`, or by deleting
-- or renaming the permission, which reaches that row by cascade. Each is
-- refused with 42501 and changes nothing: an UPDATE of user_roles with
-- hint.code 90104, like the delete, and a route that takes the authority with
-- 90108.

-- What a statement is refused with: SQLSTATE and hint.code, or 'not refused'.
-- It runs as its caller, and a refused statement leaves nothing behind.
CREATE FUNCTION pg_temp.la_refusal(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE
    v_err JSONB := catch_error(p_sql);
    v_code TEXT;
BEGIN
    IF v_err = 'null'::jsonb THEN
        RETURN 'not refused';
    END IF;
    BEGIN
        v_code := (v_err ->> 'hint')::jsonb ->> 'code';
    EXCEPTION WHEN OTHERS THEN
        v_code := NULL;
    END;
    RETURN (v_err ->> 'code') || ' ' || COALESCE(v_code, 'no hint code');
END;
$f$;

-- Fresh fixture, built as the owner: user3 is the only enabled holder of role 2
-- again, and a spare role exists to point an assignment at.
RESET ROLE;
UPDATE users SET is_disabled = FALSE WHERE id IN (1001, 1003);
INSERT INTO user_roles (user_id, role_id) VALUES (1003, 2);
INSERT INTO roles (role_name, description)
VALUES ('Last Admin Probe', 'target of a re-pointed Administrator assignment');

SELECT is(
    rbac.count_enabled_administrators(),
    1,
    'fixture: user3 is the only enabled Administrator again');

-- A floor here too: with a second Administrator the same UPDATE is ordinary.
INSERT INTO user_roles (user_id, role_id) VALUES (1001, 2);
SELECT authenticate_as('user3');

SELECT lives_ok(
    $$UPDATE user_roles
         SET role_id = (SELECT id FROM roles WHERE role_name = 'Last Admin Probe')
       WHERE user_id = 1003 AND role_id = 2$$,
    'with a second Administrator in place an assignment may be pointed at another role');

RESET ROLE;
UPDATE user_roles SET role_id = 2
 WHERE user_id = 1003 AND role_id = (SELECT id FROM roles WHERE role_name = 'Last Admin Probe');
DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2;

-- Re-pointing the row at another role: the user would keep no Administrator role.
SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$UPDATE user_roles
         SET role_id = (SELECT id FROM roles WHERE role_name = 'Last Admin Probe')
       WHERE user_id = 1003 AND role_id = 2$$),
    '42501 90104',
    'pointing the last Administrator''s assignment at another role is refused');

SELECT is(
    rbac.count_enabled_administrators(),
    1,
    'and user3 is still the enabled Administrator');

-- Re-pointing the row at another user: here a disabled one, so the role would
-- be held by somebody who cannot use it. The first statement puts the row back
-- where a case that was not refused left it elsewhere.
RESET ROLE;
UPDATE user_roles SET role_id = 2 WHERE user_id = 1003 AND role_id <> 1;
UPDATE users SET is_disabled = TRUE WHERE id = 1001;

SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$UPDATE user_roles SET user_id = 1001 WHERE user_id = 1003 AND role_id = 2$$),
    '42501 90104',
    'pointing the last Administrator''s assignment at a disabled user is refused');

SELECT is(
    rbac.count_enabled_administrators(),
    1,
    'and user3 is still the enabled Administrator (the other holder would be disabled)');

-- Taking admin away from role 2: the assignment would survive, the authority not.
RESET ROLE;
UPDATE user_roles SET user_id = 1003 WHERE user_id = 1001 AND role_id = 2;

SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$DELETE FROM role_permissions WHERE role_id = 2 AND permission_name = 'admin'$$),
    '42501 90108',
    'removing admin from the Administrator role is refused');

RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM role_permissions
      WHERE role_id = 2 AND permission_name = 'admin'),
    1,
    'and the Administrator role still grants admin');

SELECT is(
    (SELECT count(*)::integer FROM rbac.get_user_permissions_by_id(1003)
      WHERE permission_name = 'admin'),
    1,
    'and user3 still holds admin through it');

INSERT INTO role_permissions (role_id, permission_name) VALUES (2, 'admin')
ON CONFLICT DO NOTHING;

SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$UPDATE role_permissions
         SET role_id = (SELECT id FROM roles WHERE role_name = 'Last Admin Probe')
       WHERE role_id = 2 AND permission_name = 'admin'$$),
    '42501 90108',
    'pointing the Administrator role''s admin grant at another role is refused');

RESET ROLE;
DELETE FROM role_permissions
 WHERE permission_name = 'admin'
   AND role_id = (SELECT id FROM roles WHERE role_name = 'Last Admin Probe');
INSERT INTO role_permissions (role_id, permission_name) VALUES (2, 'admin')
ON CONFLICT DO NOTHING;

-- The permission itself. role_permissions follows a delete and a rename of it
-- by cascade, and a cascade runs as the table's owner, whom the guard on
-- role_permissions excuses. The foreign keys from entities refuse the delete
-- as well, with 23503; the guard answers before they do, so that the caller
-- reads why.
SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$DELETE FROM permissions WHERE permission_name = 'admin'$$),
    '42501 90108',
    'deleting the permission admin is refused');

RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM permissions WHERE permission_name = 'admin'),
    1,
    'and the permission admin still exists');

SELECT authenticate_as('user3');

SELECT is(
    pg_temp.la_refusal($$UPDATE permissions SET permission_name = 'admin_renamed' WHERE permission_name = 'admin'$$),
    '42501 90108',
    'renaming the permission admin is refused');

RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM permissions WHERE permission_name = 'admin'),
    1,
    'and the permission is still named admin');

UPDATE permissions SET permission_name = 'admin' WHERE permission_name = 'admin_renamed';

SELECT * FROM finish();
ROLLBACK;
