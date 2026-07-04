-- Test (b3, determinism guard): toggling entities.managed FALSE→TRUE must install the canonical
-- select_rule policy, not just the permission-only default policies. enable_dd_table() now calls
-- build_select_rule_policy() itself (0145), so the per-row rule is enforced regardless of the
-- alphabetical firing order of the separate manage_select_rule_policy AFTER-trigger (F3).
--
-- This pins the end-to-end invariant (I1/I10 enforcement consistency across the F→T toggle): an
-- entity defined while unmanaged WITH a select_rule, then enabled, enforces that rule. The
-- accompanying mutation check (see plan §7) confirms enable_dd_table's call carries the load:
-- with the manage_select_rule_policy managed-change arm disabled the rule is STILL enforced.
--
-- Fixtures: user3 = Administrator; user1/user2 = non-admin.
BEGIN;

SELECT plan(6);

SELECT authenticate_as('user3');

-- Define the entity UNMANAGED, with a select_rule already set (admin sees all, else own rows).
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed, select_rule)
VALUES ('em_rule_test', 'em_rule', 'EM Rule', 'EM Rules', 'managed-toggle select_rule probe',
    1, 'public:read', 'admin', 'id', 'label', FALSE,
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width,
    reference_table, reference_delete_mode)
VALUES ('em_rule_test', 'assigned_to', 'Assigned To', 'reference', 20, 'default', 'default',
    'users', 'clear');

-- While unmanaged there is no physical table and no policy yet.
SELECT ok(
    NOT EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema = 'public' AND table_name = 'em_rule_test'),
    'no physical table exists while the entity is unmanaged');

-- ── Enable it ───────────────────────────────────────────────────────────────
UPDATE entities SET managed = TRUE WHERE table_name = 'em_rule_test';

-- The per-row rule function + the SELECT policy that uses it must now exist.
SELECT ok(
    EXISTS (SELECT 1 FROM pg_proc
            WHERE proname = 'select_rule_em_rule_test'
              AND pronamespace = 'public'::regnamespace),
    'select_rule function built after managed F→T toggle');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'em_rule_test'
       AND policyname = 'em_rule_test_select_policy'
       AND qual LIKE '%select_rule_em_rule_test%'),
    1,
    'SELECT policy references the per-row rule function (not permission-only)');

-- ── behavioral enforcement of the rule ─────────────────────────────────────
DO $$
DECLARE v_u1 INT; v_u2 INT;
BEGIN
    SELECT id INTO v_u1 FROM users WHERE external_id = 'user1';
    SELECT id INTO v_u2 FROM users WHERE external_id = 'user2';
    INSERT INTO em_rule_test (label, assigned_to)
    VALUES ('for user1', v_u1), ('for user2', v_u2), ('unassigned', NULL);
END $$;

SELECT is(
    (SELECT count(*)::int FROM em_rule_test),
    3,
    'admin sees all 3 rows through the rule');

SELECT authenticate_as('user1');

SELECT is(
    (SELECT count(*)::int FROM em_rule_test),
    1,
    'user1 sees only their own row — the select_rule is enforced after the toggle');

SELECT is(
    (SELECT label FROM em_rule_test),
    'for user1',
    'the single visible row is user1''s own');

SELECT * FROM finish();
ROLLBACK;
