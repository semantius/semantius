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
BEGIN;

SELECT plan(6);

SELECT authenticate_as('user3');

-- =====================================================
-- $today: a date-typed rule "valid_until >= $today"
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule)
VALUES (
    'sel_today_rule',
    'sel_today_rule_item',
    'Sel Today Rule Item',
    'Sel Today Rule Items',
    'select_rule referencing $today',
    '{">=":[{"var":"valid_until"},{"var":"$today"}]}'::jsonb
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
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, select_rule)
VALUES (
    'sel_now_rule',
    'sel_now_rule_item',
    'Sel Now Rule Item',
    'Sel Now Rule Items',
    'select_rule referencing $now',
    '{">=":[{"var":"expires_at"},{"var":"$now"}]}'::jsonb
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
