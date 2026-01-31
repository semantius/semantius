-- Test first user auto-assignment to Administrator role
BEGIN;

SELECT plan(8);

-- =====================================================
-- TEST: First user with last_seen gets Administrator role
-- =====================================================

-- Test 1: Create the first user with last_seen and verify admin role is assigned
SELECT authenticate_as('user3'); -- user3 is the admin user with user:manage permission

-- Clear existing users with last_seen to simulate first user scenario
UPDATE users SET last_seen = NULL WHERE id IN (1001, 1002, 1003);

-- Insert the first user with last_seen
INSERT INTO users (id, external_id, email, last_seen) 
VALUES (9901, 'firstuser', 'first@test.com', CURRENT_TIMESTAMP);

-- Verify the user was created
SELECT ok(
    (SELECT COUNT(*) FROM users WHERE id = 9901) = 1,
    'First user with id 9901 should be created'
);

-- Verify role 1 (User) was automatically assigned
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9901 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to first user'
);

-- Verify role 2 (Administrator) was automatically assigned to first user
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9901 AND role_id = 2) = 1,
    'Role 2 (Administrator) should be automatically assigned to first user'
);

-- Test 2: Create a second user with last_seen and verify admin role is NOT assigned
INSERT INTO users (id, external_id, email, last_seen) 
VALUES (9902, 'seconduser', 'second@test.com', CURRENT_TIMESTAMP);

-- Verify the second user was created
SELECT ok(
    (SELECT COUNT(*) FROM users WHERE id = 9902) = 1,
    'Second user with id 9902 should be created'
);

-- Verify role 1 (User) was automatically assigned
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to second user'
);

-- Verify role 2 (Administrator) was NOT assigned to second user
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9902 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to second user'
);

-- Test 3: Create a user without last_seen and verify no admin role
INSERT INTO users (id, external_id, email, last_seen) 
VALUES (9903, 'thirduser', 'third@test.com', NULL);

-- Verify role 1 was assigned but role 2 was not
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 1) = 1,
    'Role 1 (User) should be assigned to user without last_seen'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9903 AND role_id = 2) = 0,
    'Role 2 (Administrator) should NOT be assigned to user without last_seen'
);

SELECT * FROM finish();
ROLLBACK;
