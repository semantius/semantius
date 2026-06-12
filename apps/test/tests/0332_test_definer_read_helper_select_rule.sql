-- Test (RED-FIRST): SECURITY DEFINER read helpers must honor select_rule, not just
-- view_permission. This proves the CRITICAL bypass found by the stage-2 panel:
--
--   get_record_by_id() is SECURITY DEFINER (bypasses RLS) and authorizes on the entity's
--   view_permission ALONE (0070_dd_functions.sql:1523). When an entity has a select_rule,
--   the RLS SELECT policy uses the RULE (REPLACE semantics), but get_record_by_id keeps
--   using view_permission — so any holder of view_permission (commonly public:read, which
--   EVERY user has) can read a row the select_rule hides, one id at a time. The set_record
--   JsonLogic operator and /rpc/evaluate_json_logic wrap this same primitive.
--
-- Per spec v2 (docs/authz-spec.md) the canonical predicate access(row) MUST be enforced
-- identically in the SELECT policy, the DEFINER read helpers, and the write USING clauses.
--
-- EXPECTED ON CURRENT main: the "bypass" assertion FAILS (get_record_by_id returns the
-- hidden row). After b1 (get_record_by_id applies access(row)) it goes green.
--
-- Fixtures (0030_seed.sql): user1=1001, user2=1002 (holds public:read via the User role),
-- user3=admin.
BEGIN;

SELECT plan(3);

-- =====================================================
-- SETUP (admin): entity visible only to owner-or-admin, but view_permission = public:read
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    view_permission, edit_permission, select_rule
) VALUES (
    'test_abac_read', 'test_abac_read_item', 'ABAC Read Item', 'ABAC Read Items',
    'Verifies DEFINER read helpers honor select_rule, not just view_permission',
    'public:read', 'admin',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb
);

INSERT INTO fields (
    table_name, field_name, title, format, field_order, input_type, width,
    reference_table, reference_delete_mode
) VALUES (
    'test_abac_read', 'assigned_to', 'Assigned To', 'reference', 20, 'default', 'default',
    'users', 'clear'
);

INSERT INTO test_abac_read (label, assigned_to) VALUES
    ('hidden-row', 1001),
    ('owned-row',  1002);

-- Stash the row ids: a TEMP table is owned by the semantius_user DB role (the role every
-- authenticate_as() switches into) and is not RLS-bound, so user2 can read it even though
-- user2 cannot SELECT the hidden row itself.
CREATE TEMP TABLE _abac_ids AS
    SELECT assigned_to, id FROM test_abac_read WHERE assigned_to IN (1001, 1002);

-- =====================================================
-- As user2: holds public:read, but select_rule hides the user1-owned row.
-- =====================================================
SELECT authenticate_as('user2');

-- baseline: the hidden row is invisible to user2 via direct SELECT (RLS uses the rule)
SELECT is(
    (SELECT count(*)::int FROM test_abac_read WHERE assigned_to = 1001),
    0,
    'baseline: select_rule hides the user1-owned row from user2 (direct SELECT)'
);

-- positive control: get_record_by_id returns the caller's OWN (visible) row — must stay green
SELECT is(
    (get_record_by_id('test_abac_read', (SELECT id FROM _abac_ids WHERE assigned_to = 1002)) ->> 'label'),
    'owned-row',
    'positive control: get_record_by_id returns the caller''s own visible row'
);

-- THE BYPASS: get_record_by_id must NOT return a row hidden by select_rule.
-- RED on current main (returns 'hidden-row' because only view_permission is checked).
SELECT is(
    (get_record_by_id('test_abac_read', (SELECT id FROM _abac_ids WHERE assigned_to = 1001)) ->> 'label'),
    NULL,
    'get_record_by_id must NOT return a select_rule-hidden row (canonical predicate, I1)'
);

SELECT * FROM finish();
ROLLBACK;
