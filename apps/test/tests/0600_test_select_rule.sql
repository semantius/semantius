-- select_rule: the JsonLogic FOR SELECT policy on an entity, and the
-- $today / $now variables inside it.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. select_rule policy
--   2. $today / $now inside select_rule
BEGIN;

SELECT plan(13);

-- =====================================================
-- PART 1: select_rule policy
-- =====================================================
-- Test select_rule: JsonLogic-based FOR SELECT RLS policy on entities

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

-- =====================================================
-- PART 2: $today / $now inside select_rule
-- =====================================================
-- Test: $today / $now reserved variables must be available inside select_rule.
--
-- build_select_rule_policy generates the per-row FOR SELECT rule function. The
-- compute/validate trigger injects $today, $now, $user_id, $old and $mode, but the
-- SELECT rule function historically injected only $user_id. A select_rule that filters
-- rows by server time (e.g. "only show rows still valid today") therefore saw $today/$now
-- resolve to null -> jl_to_number(null)=0, so a ">=" comparison passed for EVERY row and
-- the temporal filter did nothing.
--
-- These tests pin the invariant that a select_rule can gate row visibility on server time.
-- They FAIL until $today/$now are injected into the generated select rule function.
--
-- Dates are chosen far in the past (2000) and far in the future (2999) so the result is
-- independent of the actual server clock.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT authenticate_as('user3');

-- =====================================================
-- $today: a date-typed rule "valid_until >= $today"
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'sel_today_rule',
    'sel_today_rule_item',
    'Sel Today Rule Item',
    'Sel Today Rule Items',
    'select_rule referencing $today',
    '{">=":[{"var":"valid_until"},{"var":"$today"}]}'::jsonb,
    1
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sel_today_rule', 'valid_until', 'Valid Until', 'date', 10);

INSERT INTO sel_today_rule (label, valid_until)
VALUES ('future', '2999-01-01'), ('past', '2000-01-01');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule),
    1,
    '$today: only the still-valid (future) row is visible');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule WHERE label = 'past'),
    0,
    '$today: the expired (past) row is filtered out by the rule');

SELECT is(
    (SELECT count(*)::int FROM sel_today_rule WHERE label = 'future'),
    1,
    '$today: the future row is not over-filtered (rule is not hiding everything)');

-- =====================================================
-- $now: a date-time-typed rule "expires_at >= $now"
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule, module_id)
VALUES (
    'sel_now_rule',
    'sel_now_rule_item',
    'Sel Now Rule Item',
    'Sel Now Rule Items',
    'select_rule referencing $now',
    '{">=":[{"var":"expires_at"},{"var":"$now"}]}'::jsonb,
    1
);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sel_now_rule', 'expires_at', 'Expires At', 'date-time', 10);

INSERT INTO sel_now_rule (label, expires_at)
VALUES ('future', '2999-01-01 00:00:00+00'), ('past', '2000-01-01 00:00:00+00');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule),
    1,
    '$now: only the unexpired (future) row is visible');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule WHERE label = 'past'),
    0,
    '$now: the expired (past) row is filtered out by the rule');

SELECT is(
    (SELECT count(*)::int FROM sel_now_rule WHERE label = 'future'),
    1,
    '$now: the future row is not over-filtered (rule is not hiding everything)');

SELECT * FROM finish();
ROLLBACK;
