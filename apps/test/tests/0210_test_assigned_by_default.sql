-- Test that assigned_by defaults to the current user when not provided
BEGIN;

SELECT plan(2);

-- =====================================================
-- TEST: assigned_by defaults to current user on insert
-- =====================================================

-- Authenticate as user3 (admin with user:manage permission)
SELECT authenticate_as('user3');

-- Test 1: Insert a user_role without assigned_by — should default to current user
INSERT INTO user_roles (user_id, role_id)
VALUES (1001, 2);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1003,
    'assigned_by should default to current user (1003) when not provided'
);

-- Clean up for next test
DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 2;

-- Test 2: Insert with explicit assigned_by — should preserve the provided value
INSERT INTO user_roles (user_id, role_id, assigned_by)
VALUES (1001, 2, 1002);

SELECT is(
    (SELECT assigned_by FROM user_roles WHERE user_id = 1001 AND role_id = 2),
    1002,
    'assigned_by should preserve explicit value (1002) when provided'
);

SELECT * FROM finish();
ROLLBACK;
