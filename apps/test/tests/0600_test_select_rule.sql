-- select_rule: the JsonLogic FOR SELECT policy on an entity, and the
-- $today / $now variables inside it.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. select_rule policy
--   2. $today / $now inside select_rule
--   3. is_a records under row security: base + extension permissions, the
--      whole-record skip, a derived select_rule over the whole record
BEGIN;

SELECT plan(21);

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

-- =====================================================
-- PART 3: is_a records under row security
-- =====================================================
-- A derived entity's record is stored in its base's table and in its own
-- <entity>_ext, each carrying its own entity's policies. The view is
-- security_invoker, so a reader needs the view permission of every level; a
-- write runs as the caller, locks every level it writes first, and skips the
-- whole record when one of them cannot be locked - never half of it.
-- sec_parties is readable by everyone and editable with nwind:manage;
-- sec_leads is readable with nwind:view and editable by admin only. user1
-- holds neither nwind permission, user2 (Northwind Sales) both.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix,
                      view_permission, edit_permission)
VALUES ('sec_parties', 'Party', 'Parties', 1, 'typeid', 'secpty', 'public:read', 'nwind:manage');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sec_parties', 'region', 'Region', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, edit_permission)
VALUES ('sec_leads', 'Lead', 'Leads', 1, 'is_a', 'secled', 'sec_parties', 'nwind:view', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sec_leads', 'score', 'Score', 'int32', 30);

INSERT INTO sec_parties (label, region) VALUES ('p1', 'north');
INSERT INTO sec_leads (label, region, score) VALUES ('l1', 'north', 1), ('l2', 'south', 2);

SELECT authenticate_as('user1');
SELECT is(
    (SELECT count(*)::int FROM sec_parties)::text || '/' || (SELECT count(*)::int FROM sec_leads)::text,
    '3/0',
    'families: a reader sees the root rows its permission allows, and a subtype record only with every level''s view permission');

SELECT authenticate_as('user2');
SELECT is((SELECT count(*)::int FROM sec_leads), 2,
    'families: with the view permission of every level the subtype records are readable');

SELECT throws_ok($$ INSERT INTO sec_leads (label) VALUES ('l3') $$,
    '42501', NULL,
    'families: an insert needs the edit permission of every level, and fails as a whole');

UPDATE sec_leads SET region = 'east' WHERE label = 'l1';
SELECT is((SELECT region FROM sec_leads WHERE label = 'l1'), 'north',
    'families: an update that cannot lock every level it writes skips the record, root row included');

UPDATE sec_parties SET region = 'west';
SELECT is(
    (SELECT string_agg(label || '=' || region, ', ' ORDER BY label) FROM sec_parties),
    'l1=north, l2=south, p1=west',
    'families: through the root table as well - the plain row changes, the subtype records are skipped whole');

DELETE FROM sec_parties;
SELECT is(
    (SELECT string_agg(label, ', ' ORDER BY label) FROM sec_parties),
    'l1, l2',
    'families: a delete through the root skips the subtype records it may not delete entirely');

-- A select_rule on a derived entity sees the whole record: its policy on
-- <entity>_ext merges the base's row under the own one.
SELECT authenticate_as('user3');
UPDATE entities SET select_rule = '{"==":[{"var":"region"},"north"]}'::jsonb WHERE table_name = 'sec_leads';
SELECT authenticate_as('user2');
SELECT is(
    (SELECT string_agg(label, ', ') FROM sec_leads),
    'l1',
    'families: a derived entity''s select_rule reads the fields its base stores');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'select_rule_sec_leads'
              AND pg_get_function_identity_arguments(oid) = 'p_row sec_leads_ext, p_ctx jsonb'),
    'families: the rule function takes the row of <entity>_ext and keeps the entity''s name');

SELECT * FROM finish();
ROLLBACK;
