-- Test rbac.check_permission_hierarchy_cycle (0030_rbac_functions.sql): the
-- BEFORE INSERT/UPDATE trigger on permission_hierarchy that rejects cycles and
-- enforces the 11-level depth limit. Also pins the no_self_reference CHECK, the
-- two foreign keys to permissions(permission_name), admin-only RLS, and that
-- the hierarchy actually RESOLVES (including implies included, not the reverse).
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

INSERT INTO permission_hierarchy (including_permission_name, included_permission_name) VALUES
    ('phc:a', 'phc:b'),
    ('phc:b', 'phc:c');

-- Test 1
SELECT is(
    (SELECT count(*)::int FROM permission_hierarchy
      WHERE including_permission_name IN ('phc:a', 'phc:b')
        AND included_permission_name  IN ('phc:b', 'phc:c')),
    2,
    'setup: chain phc:a -> phc:b -> phc:c is in place'
);

-- =====================================================
-- CYCLE REJECTION
-- =====================================================

-- Test 2: self-reference is stopped by the CHECK constraint, not the trigger
SELECT throws_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:a', 'phc:a') $$,
    '23514', NULL,
    'self-reference a -> a is rejected (no_self_reference CHECK)'
);

-- Test 3: direct two-node cycle
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:b', 'phc:a') $$,
    '%would create a cycle%',
    'b -> a closes a two-node cycle and is rejected'
);

-- Test 4: transitive three-node cycle
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:c', 'phc:a') $$,
    '%would create a cycle%',
    'c -> a closes a three-node cycle and is rejected'
);

-- Test 5: the trigger also guards UPDATE
SELECT throws_like(
    $$ UPDATE permission_hierarchy
          SET included_permission_name = 'phc:a'
        WHERE including_permission_name = 'phc:b'
          AND included_permission_name  = 'phc:c' $$,
    '%would create a cycle%',
    'rewiring b -> c into b -> a via UPDATE is rejected'
);

-- =====================================================
-- EXISTENCE: the two foreign keys, not a hand-written check
-- =====================================================

-- Test 6
SELECT throws_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:nosuch', 'phc:a') $$,
    '23503', NULL,
    'an unknown including permission is rejected by the foreign key'
);

-- Test 7
SELECT throws_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:a', 'phc:nosuch') $$,
    '23503', NULL,
    'an unknown included permission is rejected by the foreign key'
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
        INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
        VALUES ('phc:d' || i, 'phc:d' || (i + 1));
    END LOOP;
END
$do$;

-- Test 8: downstream depth from phc:d2 is 10 — still allowed
SELECT lives_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:d0', 'phc:d2') $$,
    'an edge with downstream depth 10 is allowed (limit boundary)'
);

-- Test 9: downstream depth from phc:d1 is 11 — blocked
SELECT throws_like(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:d0', 'phc:d1') $$,
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

INSERT INTO permission_hierarchy (including_permission_name, included_permission_name) VALUES
    ('phc:parent',  'phc:child'),
    ('phc:parent2', 'phc:child2');

-- User role gets the parent (implies child) and child2 (must NOT imply parent2)
INSERT INTO role_permissions (role_id, permission_name) VALUES
    ((SELECT id FROM roles WHERE role_name = 'User'), 'phc:parent'),
    ((SELECT id FROM roles WHERE role_name = 'User'), 'phc:child2');

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

-- Test 14: a non-admin INSERT is denied by the RLS WITH CHECK. The row itself
-- is legal — phc:a -> phc:c is neither a cycle nor over the depth limit, and a
-- referential check runs with RLS off, so both names resolve — which is what
-- makes 42501 the only thing that can stop it.
SELECT throws_ok(
    $$ INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
       VALUES ('phc:a', 'phc:c') $$,
    '42501', NULL,
    'non-admin cannot write permission_hierarchy'
);

SELECT * FROM finish();
ROLLBACK;
