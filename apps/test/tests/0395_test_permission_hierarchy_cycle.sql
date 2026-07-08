-- Test rbac.check_permission_hierarchy_cycle (0030_rbac_functions.sql): the
-- BEFORE INSERT/UPDATE trigger on permission_hierarchy that rejects cycles and
-- enforces the 11-level depth limit. Also pins the no_self_reference CHECK,
-- the trigger's explicit existence checks, admin-only RLS, and that the
-- hierarchy actually RESOLVES (including implies included, not the reverse).
--
-- Fixtures (0030_seed.sql): user1=1001 (User role only), user3=admin.
BEGIN;

SELECT plan(14);

SELECT authenticate_as('user3');

-- =====================================================
-- SETUP: three permissions chained phc:a -> phc:b -> phc:c
-- =====================================================
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('phc:a', 'cycle test a', 1),
    ('phc:b', 'cycle test b', 1),
    ('phc:c', 'cycle test c', 1);

CREATE TEMP TABLE _phc AS
SELECT
    (SELECT id FROM permissions WHERE permission_name = 'phc:a') AS a,
    (SELECT id FROM permissions WHERE permission_name = 'phc:b') AS b,
    (SELECT id FROM permissions WHERE permission_name = 'phc:c') AS c;

INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
SELECT a, b FROM _phc;
INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
SELECT b, c FROM _phc;

-- Test 1
SELECT is(
    (SELECT count(*)::int FROM permission_hierarchy
      WHERE including_permission_id IN (SELECT a FROM _phc UNION SELECT b FROM _phc)
        AND included_permission_id  IN (SELECT b FROM _phc UNION SELECT c FROM _phc)),
    2,
    'setup: chain phc:a -> phc:b -> phc:c is in place'
);

-- =====================================================
-- CYCLE REJECTION
-- =====================================================

-- Test 2: self-reference is stopped by the CHECK constraint, not the trigger
SELECT throws_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT a, a FROM _phc $$,
    '23514', NULL,
    'self-reference a -> a is rejected (no_self_reference CHECK)'
);

-- Test 3: direct two-node cycle
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT b, a FROM _phc $$,
    '%would create a cycle%',
    'b -> a closes a two-node cycle and is rejected'
);

-- Test 4: transitive three-node cycle
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT c, a FROM _phc $$,
    '%would create a cycle%',
    'c -> a closes a three-node cycle and is rejected'
);

-- Test 5: the trigger also guards UPDATE
SELECT throws_like(
    $$ UPDATE permission_hierarchy
          SET included_permission_id = (SELECT a FROM _phc)
        WHERE including_permission_id = (SELECT b FROM _phc)
          AND included_permission_id  = (SELECT c FROM _phc) $$,
    '%would create a cycle%',
    'rewiring b -> c into b -> a via UPDATE is rejected'
);

-- =====================================================
-- EXISTENCE CHECKS
-- =====================================================

-- Test 6
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT 999999, a FROM _phc $$,
    '%Including permission with Id 999999 does not exist%',
    'unknown including permission id is rejected with an explicit error'
);

-- Test 7
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT a, 999999 FROM _phc $$,
    '%Included permission with Id 999999 does not exist%',
    'unknown included permission id is rejected with an explicit error'
);

-- =====================================================
-- DEPTH LIMIT: chain phc:d1 -> ... -> phc:d12 (11 edges)
-- =====================================================
INSERT INTO permissions (permission_name, description, module_id)
SELECT 'phc:d' || i, 'depth test ' || i, 1 FROM generate_series(0, 12) AS i;

DO $do$
DECLARE
    i INT;
BEGIN
    FOR i IN 1..11 LOOP
        INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
        VALUES (
            (SELECT id FROM permissions WHERE permission_name = 'phc:d' || i),
            (SELECT id FROM permissions WHERE permission_name = 'phc:d' || (i + 1))
        );
    END LOOP;
END
$do$;

-- Test 8: downstream depth from phc:d2 is 10 — still allowed
SELECT lives_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       VALUES ((SELECT id FROM permissions WHERE permission_name = 'phc:d0'),
               (SELECT id FROM permissions WHERE permission_name = 'phc:d2')) $$,
    'an edge with downstream depth 10 is allowed (limit boundary)'
);

-- Test 9: downstream depth from phc:d1 is 11 — blocked
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       VALUES ((SELECT id FROM permissions WHERE permission_name = 'phc:d0'),
               (SELECT id FROM permissions WHERE permission_name = 'phc:d1')) $$,
    '%maximum depth of 11 levels%',
    'an edge with downstream depth 11 exceeds the limit and is rejected'
);

-- =====================================================
-- RESOLUTION: including implies included, not the reverse
-- =====================================================
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('phc:parent',  'resolution test parent',  1),
    ('phc:child',   'resolution test child',   1),
    ('phc:parent2', 'resolution test parent2', 1),
    ('phc:child2',  'resolution test child2',  1);

INSERT INTO permission_hierarchy (including_permission_id, included_permission_id) VALUES
    ((SELECT id FROM permissions WHERE permission_name = 'phc:parent'),
     (SELECT id FROM permissions WHERE permission_name = 'phc:child')),
    ((SELECT id FROM permissions WHERE permission_name = 'phc:parent2'),
     (SELECT id FROM permissions WHERE permission_name = 'phc:child2'));

-- User role gets the parent (implies child) and child2 (must NOT imply parent2)
INSERT INTO role_permissions (role_id, permission_id) VALUES
    ((SELECT id FROM roles WHERE role_name = 'User'),
     (SELECT id FROM permissions WHERE permission_name = 'phc:parent')),
    ((SELECT id FROM roles WHERE role_name = 'User'),
     (SELECT id FROM permissions WHERE permission_name = 'phc:child2'));

SELECT authenticate_as('user1');

-- Test 10
SELECT ok(
    rbac.has_permission('phc:parent'),
    'user1 holds phc:parent directly via the User role'
);

-- Test 11
SELECT ok(
    rbac.has_permission('phc:child'),
    'phc:child is implied through the hierarchy'
);

-- Test 12
SELECT ok(
    NOT rbac.has_permission('phc:parent2'),
    'holding the included side does not imply the including side'
);

-- =====================================================
-- RLS: the hierarchy is admin-only
-- =====================================================

-- Test 13: still authenticated as user1 — SELECT policy hides every row
SELECT is(
    (SELECT count(*)::int FROM permission_hierarchy),
    0,
    'non-admin sees no permission_hierarchy rows'
);

-- Test 14: a non-admin INSERT is denied. Note: the BEFORE trigger runs before
-- the RLS WITH CHECK, and RLS hides the permissions rows from non-admins, so
-- the denial surfaces as the trigger's existence error rather than 42501.
-- (phc:a -> phc:c would be a legal edge — only RLS stands in the way.)
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
       SELECT a, c FROM _phc $$,
    '%does not exist%',
    'non-admin cannot write permission_hierarchy'
);

SELECT * FROM finish();
ROLLBACK;
