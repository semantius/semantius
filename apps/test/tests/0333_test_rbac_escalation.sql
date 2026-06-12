-- Test (PIN, expected GREEN): a non-admin cannot escalate by writing the RBAC tables.
--
-- The stage-2 panel checked these and found them correctly forbidden (the RBAC tables are
-- admin-gated via RLS WITH CHECK, 0050_rbac_rls.sql), but UNTESTED — so this pins invariant
-- I5 (no privilege escalation) against regression. Unlike 0331/0332 these should PASS now.
--
-- Fixtures: user1=1001 (plain user, holds the User role = role 1), user3=admin.
BEGIN;

SELECT plan(4);

-- Stash valid ids as admin so each attempt below fails ONLY on RLS (42501), not on a bad FK.
SELECT authenticate_as('user3');
CREATE TEMP TABLE _esc AS
SELECT
    (SELECT id FROM roles       WHERE role_name       = 'Administrator') AS admin_role,
    (SELECT id FROM roles       WHERE role_name       = 'User')          AS user_role,
    (SELECT id FROM permissions WHERE permission_name = 'admin')         AS admin_perm;

-- =====================================================
-- As user1 (non-admin): every self-grant path must be rejected by RLS (42501).
-- =====================================================
SELECT authenticate_as('user1');

-- 1. Self-assign the Administrator role via user_roles.
SELECT throws_ok(
    $$ INSERT INTO user_roles (user_id, role_id)
       VALUES (1001, (SELECT admin_role FROM _esc)) $$,
    '42501', NULL,
    'I5: user1 cannot self-grant Administrator via user_roles'
);

-- 2. Self-grant the admin permission directly via user_permissions.
SELECT throws_ok(
    $$ INSERT INTO user_permissions (user_id, permission_id)
       VALUES (1001, (SELECT admin_perm FROM _esc)) $$,
    '42501', NULL,
    'I5: user1 cannot self-grant the admin permission via user_permissions'
);

-- 3. Grant the admin permission to the User role (which user1 holds) via role_permissions.
SELECT throws_ok(
    $$ INSERT INTO role_permissions (role_id, permission_id)
       VALUES ((SELECT user_role FROM _esc), (SELECT admin_perm FROM _esc)) $$,
    '42501', NULL,
    'I5: user1 cannot grant admin to the User role via role_permissions'
);

-- 4. Insert a brand-new permission (which would auto-grant to Administrator).
SELECT throws_ok(
    $$ INSERT INTO permissions (permission_name, description)
       VALUES ('evil:escalate', 'should be rejected') $$,
    '42501', NULL,
    'I5: user1 cannot create a permission'
);

SELECT * FROM finish();
ROLLBACK;
