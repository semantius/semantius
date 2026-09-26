-- Test user_permissions: direct per-user permission grants
BEGIN;

SELECT plan(21);

-- =====================================================
-- TEST 1: authenticate_as is not in public schema
-- =====================================================
-- PostgREST only exposes functions from its configured schema (public).
-- authenticate_as must live in pgtap schema so it cannot be called via the API.

SELECT is(
    (SELECT COUNT(*)::integer
     FROM pg_proc p
     JOIN pg_namespace n ON p.pronamespace = n.oid
     WHERE p.proname = 'authenticate_as'
       AND n.nspname = 'public'),
    0,
    'authenticate_as should not exist in public schema (not callable from PostgREST)'
);

-- =====================================================
-- TEST 2: user1 should not be able to read roles (no admin permission)
-- =====================================================

SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM roles),
    0,
    'user1 without admin permission should not be able to read roles'
);

RESET ROLE;

-- =====================================================
-- TEST 3: Assign admin permission directly to user1,
-- user1 should now be able to query roles
-- =====================================================

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, p.permission_name
FROM users u, permissions p
WHERE u.external_id = 'user1'
  AND p.permission_name = 'admin';

SELECT authenticate_as('user1');

SELECT cmp_ok(
    (SELECT COUNT(*)::integer FROM roles),
    '>',
    0,
    'user1 with direct admin permission should be able to query roles'
);

RESET ROLE;

-- Clean up: remove admin from user1
DELETE FROM user_permissions
WHERE user_id = (SELECT id FROM users WHERE external_id = 'user1')
  AND permission_name = 'admin';

-- =====================================================
-- TEST 4: user_permissions table exists
-- =====================================================

SELECT has_table('public', 'user_permissions', 'user_permissions table should exist');

-- =====================================================
-- TEST 5: user_permissions has RLS enabled
-- =====================================================

SELECT is(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'user_permissions'),
    TRUE,
    'user_permissions table should have RLS enabled'
);

-- =====================================================
-- TEST 6: user_permissions entity metadata exists
-- =====================================================

SELECT is(
    (SELECT COUNT(*)::integer FROM entities WHERE table_name = 'user_permissions'),
    1,
    'user_permissions entity metadata should exist'
);

-- =====================================================
-- TEST 7: user_permissions fields metadata exists (5 fields: id, user_id, permission_name, granted_at, granted_by)
-- =====================================================

SELECT is(
    (SELECT COUNT(*)::integer FROM fields WHERE table_name = 'user_permissions'),
    5,
    'user_permissions should have 5 fields defined in metadata'
);

-- =====================================================
-- TEST 8: Create test:test permission, assign to user1,
-- delete the permission, verify user_permissions record is cascade-deleted
-- =====================================================

INSERT INTO permissions (permission_name, description, module_id)
VALUES ('test:test', 'Temporary test permission', 1);

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, p.permission_name
FROM users u, permissions p
WHERE u.external_id = 'user1'
  AND p.permission_name = 'test:test';

-- Verify the record exists
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     JOIN permissions p ON up.permission_name = p.permission_name
     WHERE p.permission_name = 'test:test'),
    1,
    'user_permissions should have test:test assigned to user1'
);

-- Delete the permission
DELETE FROM permissions WHERE permission_name = 'test:test';

-- Verify cascade deletion
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     WHERE up.permission_name NOT IN (SELECT permission_name FROM permissions)),
    0,
    'Deleting a permission should cascade-delete user_permissions records'
);

-- =====================================================
-- TEST 10: Create a TEST user, assign admin permission,
-- delete the user, verify user_permissions record is cascade-deleted
-- =====================================================

INSERT INTO users (external_id, email) VALUES ('TEST', 'test_user@test.com');

INSERT INTO user_permissions (user_id, permission_name)
SELECT u.id, p.permission_name
FROM users u, permissions p
WHERE u.external_id = 'TEST'
  AND p.permission_name = 'admin';

-- Verify record exists
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     JOIN users u ON up.user_id = u.id
     WHERE u.external_id = 'TEST'),
    1,
    'user_permissions should have admin assigned to TEST user'
);

-- Delete the user
DELETE FROM users WHERE external_id = 'TEST';

-- Verify cascade deletion
SELECT is(
    (SELECT COUNT(*)::integer FROM user_permissions up
     WHERE up.user_id NOT IN (SELECT id FROM users)),
    0,
    'Deleting a user should cascade-delete user_permissions records'
);

-- =====================================================
-- TEST 11: rbac.get_user_permissions_by_id matches the CTE it replaced
-- =====================================================
-- pg_temp copy of the query get_user_permissions used to run inline, before it
-- delegated to get_user_permissions_by_id, keyed by internal id instead of
-- external_id (the same row, one join shorter). Swept against the real
-- function for every seeded user plus fixtures built here for the shapes the
-- seeded users don't cover: a direct user_permissions grant with no role, a
-- three-level permission_hierarchy chain reached through a role, a disabled
-- user who holds that same role, and a user with no roles or grants at all.
RESET ROLE;

CREATE FUNCTION pg_temp.old_get_user_permissions_by_id(p_user_id BIGINT)
RETURNS TABLE (permission_name TEXT) AS $$
    WITH RECURSIVE permission_tree AS (
        SELECT DISTINCT rp.permission_name
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        WHERE u.id = p_user_id
          AND u.is_disabled = FALSE

        UNION

        SELECT DISTINCT up.permission_name
        FROM users u
        JOIN user_permissions up ON u.id = up.user_id
        WHERE u.id = p_user_id
          AND u.is_disabled = FALSE

        UNION

        SELECT DISTINCT ph.included_permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_name = ph.including_permission_name
    )
    SELECT DISTINCT pt.permission_name FROM permission_tree pt ORDER BY pt.permission_name;
$$ LANGUAGE sql STABLE;

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('hotpath:a', 'equivalence sweep: top of a three-level chain', 1),
    ('hotpath:b', 'equivalence sweep: middle of the chain', 1),
    ('hotpath:c', 'equivalence sweep: bottom of the chain, and the direct-grant probe', 1);

INSERT INTO permission_hierarchy (including_permission_name, included_permission_name) VALUES
    ('hotpath:a', 'hotpath:b'),
    ('hotpath:b', 'hotpath:c');

INSERT INTO roles (role_name, description, module_id)
VALUES ('Hotpath Sweep Role', 'equivalence sweep: grants the top of the chain', 1);

INSERT INTO role_permissions (role_id, permission_name)
SELECT id, 'hotpath:a' FROM roles WHERE role_name = 'Hotpath Sweep Role';

INSERT INTO users (external_id, email) VALUES
    ('hotpath-direct-grant', 'hotpath-direct-grant@test.com'),
    ('hotpath-hierarchy',    'hotpath-hierarchy@test.com'),
    ('hotpath-disabled',     'hotpath-disabled@test.com'),
    ('hotpath-no-roles',     'hotpath-no-roles@test.com');

INSERT INTO user_permissions (user_id, permission_name)
SELECT id, 'hotpath:c' FROM users WHERE external_id = 'hotpath-direct-grant';

INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id FROM users u, roles r
WHERE u.external_id IN ('hotpath-hierarchy', 'hotpath-disabled')
  AND r.role_name = 'Hotpath Sweep Role';

UPDATE users SET is_disabled = TRUE WHERE external_id = 'hotpath-disabled';

SELECT is(
    (SELECT count(*)::int FROM users u
     WHERE EXISTS (
        (SELECT permission_name FROM pg_temp.old_get_user_permissions_by_id(u.id)
         EXCEPT
         SELECT permission_name FROM rbac.get_user_permissions_by_id(u.id))
        UNION ALL
        (SELECT permission_name FROM rbac.get_user_permissions_by_id(u.id)
         EXCEPT
         SELECT permission_name FROM pg_temp.old_get_user_permissions_by_id(u.id))
     )),
    0,
    'get_user_permissions_by_id matches the old inline CTE for every user, seeded and ephemeral alike'
);

-- A subset check, not exact equality: this user also keeps the role every new
-- user is auto-assigned (rbac.auto_assign_user_role, role 1), which is
-- irrelevant to what this fixture tests - that a role grant of the top
-- permission reaches the bottom of a three-level chain.
SELECT is(
    (SELECT array_agg(permission_name ORDER BY permission_name) FROM rbac.get_user_permissions_by_id(
        (SELECT id FROM users WHERE external_id = 'hotpath-hierarchy'))
     WHERE permission_name LIKE 'hotpath:%'),
    ARRAY['hotpath:a', 'hotpath:b', 'hotpath:c'],
    'a role grant of the top permission reaches all three levels of the hierarchy'
);

SELECT is(
    (SELECT count(*)::int FROM rbac.get_user_permissions_by_id(
        (SELECT id FROM users WHERE external_id = 'hotpath-disabled'))),
    0,
    'a disabled user has no permissions even while holding a role that would otherwise grant them'
);

-- rbac.auto_assign_user_role unconditionally assigns role 1 (User) to every
-- new row and rbac.prevent_user_role_deletion refuses to ever let it go, so
-- "no roles or grants" means none beyond that mandatory baseline: no hotpath:*
-- permission should appear for a user this sweep never granted one to.
SELECT is(
    (SELECT count(*)::int FROM rbac.get_user_permissions_by_id(
        (SELECT id FROM users WHERE external_id = 'hotpath-no-roles'))
     WHERE permission_name LIKE 'hotpath:%'),
    0,
    'a user with no roles or grants beyond the mandatory baseline holds none of the sweep permissions'
);

SELECT is(
    (SELECT array_agg(permission_name ORDER BY permission_name) FROM rbac.get_user_permissions_by_id(
        (SELECT id FROM users WHERE external_id = 'hotpath-direct-grant'))
     WHERE permission_name LIKE 'hotpath:%'),
    ARRAY['hotpath:c'],
    'a direct user_permissions grant is returned with no role or hierarchy involved'
);

SELECT is(
    (SELECT count(*)::int FROM rbac.get_user_permissions_by_id(NULL)),
    0,
    'get_user_permissions_by_id(NULL) returns no rows'
);

SELECT ok(
    NOT pg_catalog.has_function_privilege('semantius_user', 'rbac.get_user_permissions_by_id(bigint)', 'EXECUTE'),
    'get_user_permissions_by_id is not executable by semantius_user'
);

SELECT ok(
    NOT (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'rbac' AND p.proname = 'get_user_permissions_by_id'),
    'get_user_permissions_by_id is not a definer - it runs as whatever context calls it'
);

-- The wrapper's self-or-admin guard is unaffected by the refactor: it still
-- runs before the delegation, on the same external_id it always checked.
SELECT authenticate_as('user1');
SELECT throws_ok(
    $$SELECT * FROM rbac.get_user_permissions('user3')$$,
    '42501', NULL,
    'get_user_permissions: a plain user still cannot ask about another subject'
);
RESET ROLE;

-- A disabled user authenticates fine at the JWT layer - is_disabled is a
-- users-row property, not a claims one - so the cold context still has to
-- resolve the row and still raises 90006 (hint.code) on 42501 (wire) when it
-- finds none, exactly as an unknown subject does.
SELECT set_config('request.jwt.claim.sub', 'hotpath-disabled', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.email', '', true);
SELECT set_config('request.jwt.claim.aud', '', true);
SELECT set_config('app.current_user_id', NULL, false);
SELECT set_config('app.current_external_id', NULL, false);
SELECT set_config('app.user_permissions', NULL, false);
SELECT set_config('app.context_initialized', NULL, false);
SELECT set_config('app.oauth_scopes', NULL, false);
SET ROLE semantius_user;
SELECT set_config('search_path', 'pgtap, public', true);

SELECT throws_ok(
    $$SELECT rbac.user_id()$$,
    '42501', NULL,
    'a disabled user''s cold context still raises rather than resolving to a null or zero id'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
