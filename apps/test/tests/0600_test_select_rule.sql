-- Test select_rule: JsonLogic-based FOR SELECT RLS policy on entities
BEGIN;

SELECT plan(7);

-- Authenticate as admin to create test entity
SELECT authenticate_as('user3');

-- =====================================================
-- TEST 1: Create an entity with a select_rule
-- =====================================================
-- Rule: admin can see all rows, otherwise only rows where assigned_to = $user_id
-- {"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'test_select_rule',
    'test_select_rule_item',
    'Test Select Rule Item',
    'Test Select Rule Items',
    'Table for testing select_rule',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb,
    1
);

-- Add an assigned_to field (reference to users)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, reference_table, reference_delete_mode)
VALUES ('test_select_rule', 'assigned_to', 'Assigned To', 'reference', 20, 'default', 'default', 'users', 'clear');

-- =====================================================
-- TEST 2: Verify the select_rule function was created
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'select_rule_test_select_rule'
          AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
    ),
    'select_rule function should be created for test_select_rule'
);

-- =====================================================
-- TEST 3: Verify the select policy was created
-- =====================================================

SELECT ok(
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'test_select_rule'
          AND policyname = 'test_select_rule_select_policy'
    ),
    'select policy should exist for test_select_rule'
);

-- =====================================================
-- TEST 4: Insert test data as admin
-- =====================================================
-- Get user IDs for user1 and user2
DO $$
DECLARE
    v_user1_id INTEGER;
    v_user2_id INTEGER;
BEGIN
    SELECT id INTO v_user1_id FROM users WHERE external_id = 'user1';
    SELECT id INTO v_user2_id FROM users WHERE external_id = 'user2';

    INSERT INTO test_select_rule (label, assigned_to)
    VALUES ('Item for user1', v_user1_id),
           ('Item for user2', v_user2_id),
           ('Unassigned item', NULL);
END $$;

-- Admin should see all 3 rows
SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    3,
    'admin (user3) should see all 3 rows'
);

-- =====================================================
-- TEST 5: user1 should only see their own row
-- =====================================================
SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    1,
    'user1 should see only 1 row (their assigned row)'
);

SELECT is(
    (SELECT label FROM test_select_rule LIMIT 1),
    'Item for user1',
    'user1 should see only their assigned item'
);

-- =====================================================
-- TEST 6: user2 should only see their own row
-- =====================================================
SELECT authenticate_as('user2');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    1,
    'user2 should see only 1 row (their assigned row)'
);

-- =====================================================
-- TEST 7: After removing select_rule, default policy is restored
-- =====================================================
SELECT authenticate_as('user3');

UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'test_select_rule';

-- Now all users with view permission should see all rows
SELECT authenticate_as('user1');

SELECT is(
    (SELECT COUNT(*)::integer FROM test_select_rule),
    3,
    'user1 should see all 3 rows after select_rule is cleared (default policy restored)'
);

SELECT * FROM finish();
ROLLBACK;
