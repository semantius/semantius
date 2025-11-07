-- Test auto-assignment of role 1 and prevention of role 1 deletion
BEGIN;

SELECT plan(11);

-- =====================================================
-- TEST: New users are automatically assigned role 1
-- =====================================================

-- Test 1: Create a new user and verify role 1 is auto-assigned
SELECT authenticate_as('user3'); -- Use admin to have permission to insert users

-- Insert a new test user
INSERT INTO users (user_id, external_id, email) 
VALUES (9001, 'testuser1', 'testuser1@test.com');

-- Verify the user was created
SELECT ok(
    (SELECT COUNT(*) FROM users WHERE user_id = 9001) = 1,
    'New user with user_id 9001 should be created'
);

-- Verify role 1 was automatically assigned
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9001 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to new user 9001'
);

-- Test 2: Create another user and verify role 1 is auto-assigned
INSERT INTO users (user_id, external_id, email) 
VALUES (9002, 'testuser2', 'testuser2@test.com');

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 9002 AND role_id = 1) = 1,
    'Role 1 (User) should be automatically assigned to new user 9002'
);

-- Test 3: Verify existing test users already have role 1
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1001 AND role_id = 1) = 1,
    'Existing user 1001 should have role 1 (User)'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1002 AND role_id = 1) = 1,
    'Existing user 1002 should have role 1 (User)'
);

SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1003 AND role_id = 1) = 1,
    'Existing user 1003 should have role 1 (User)'
);

-- =====================================================
-- TEST: Role 1 cannot be deleted from any user
-- =====================================================

-- Test 4: Attempt to delete role 1 from user 1001 should fail
SELECT throws_ok(
    'DELETE FROM user_roles WHERE user_id = 1001 AND role_id = 1',
    'P0001',
    'Cannot delete role 1 (User) from user. All users must have the User role.',
    'Deleting role 1 from user 1001 should raise an exception'
);

-- Test 5: Attempt to delete role 1 from newly created user should fail
SELECT throws_ok(
    'DELETE FROM user_roles WHERE user_id = 9001 AND role_id = 1',
    'P0001',
    'Cannot delete role 1 (User) from user. All users must have the User role.',
    'Deleting role 1 from new user 9001 should raise an exception'
);

-- Test 6: Verify user 1002 still has role 1 after deletion attempt
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1002 AND role_id = 1) = 1,
    'User 1002 should still have role 1 after deletion attempt'
);

-- Test 7: Verify that other roles CAN be deleted (role 2 from user 1003)
-- First, verify user 1003 has role 2 (Administrator)
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1003 AND role_id = 2) = 1,
    'User 1003 should have role 2 (Administrator) before deletion test'
);

-- Delete role 2 from user 1003 (this should succeed)
DELETE FROM user_roles WHERE user_id = 1003 AND role_id = 2;

-- Verify role 2 was successfully deleted
SELECT ok(
    (SELECT COUNT(*) FROM user_roles WHERE user_id = 1003 AND role_id = 2) = 0,
    'Role 2 (Administrator) should be successfully deleted from user 1003'
);

SELECT * FROM finish();
ROLLBACK;
