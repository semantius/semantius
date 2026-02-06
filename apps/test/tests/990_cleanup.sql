-- =====================================================
-- CLEANUP: Reset test user state after all tests
-- =====================================================
-- This test runs last (990) to ensure all test users have
-- their last_seen cleared, preventing unintended admin role
-- assignments in subsequent test runs.
-- =====================================================

BEGIN;

SELECT plan(4);

-- Verify user1 has NULL last_seen (will be NULL initially or after previous cleanup)
SELECT is(
    (SELECT last_seen FROM users WHERE id = 1001),
    NULL,
    'user1 (id 1001) should have NULL last_seen after cleanup'
);

-- Verify user2 has NULL last_seen
SELECT is(
    (SELECT last_seen FROM users WHERE id = 1002),
    NULL,
    'user2 (id 1002) should have NULL last_seen after cleanup'
);

-- Verify user3 has NULL last_seen
SELECT is(
    (SELECT last_seen FROM users WHERE id = 1003),
    NULL,
    'user3 (id 1003) should have NULL last_seen after cleanup'
);

-- Verify user3 still has Administrator role
SELECT is(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1003 AND role_id = 2),
    1::bigint,
    'user3 should have Administrator role (assigned in seed data)'
);

SELECT * FROM finish();

ROLLBACK;

-- Perform the actual cleanup UPDATE outside the pgTAP transaction
-- This ensures pgTAP state is properly cleaned up (ROLLBACK) while
-- the data cleanup persists (separate UPDATE statement)
UPDATE users SET last_seen = NULL WHERE id IN (1001, 1002, 1003);
