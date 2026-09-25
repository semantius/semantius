-- SECURITY DEFINER read helpers must authorize like RLS does: honor
-- select_rule, and check permissions on every entry point.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. get_record_by_id honors select_rule
--   2. Read-helper completeness
BEGIN;

SELECT plan(11);

-- =====================================================
-- PART 1: get_record_by_id honors select_rule
-- =====================================================
-- Test (RED-FIRST): SECURITY DEFINER read helpers must honor select_rule, not just
-- view_permission. This proves the CRITICAL bypass found by the stage-2 panel:
--
--   get_record_by_id() is SECURITY DEFINER (bypasses RLS) and authorizes on the entity's
--   view_permission ALONE (get_record_by_id in 0160_dd_functions.sql). When an entity has a select_rule,
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
-- Fixtures (apps/test/migrations/0030_seed.once.sql): user1=1001, user2=1002 (holds public:read via the User role),
-- user3=admin.

-- =====================================================
-- SETUP (admin): entity visible only to owner-or-admin, but view_permission = public:read
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label, description,
    view_permission, edit_permission, select_rule, module_id
) VALUES (
    'test_abac_read', 'test_abac_read_item', 'ABAC Read Item', 'ABAC Read Items',
    'Verifies DEFINER read helpers honor select_rule, not just view_permission',
    'public:read', 'admin',
    '{"or":[{"has_permission":"admin"},{"==":[{"var":"assigned_to"},{"var":"$user_id"}]}]}'::jsonb,
    1
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

-- =====================================================
-- PART 2: Read-helper completeness
-- =====================================================
-- Test (b9, RED-FIRST on pre-b9 code): close the read-helper completeness gaps the stage-2 panel
-- found but b1 did not cover (spec v2 Appendix A "FOUND-BUT-NOT-FIXED").
--
--   1. build_schema_for_table was GRANTed to the request role with NO permission check, so any
--      public:read holder read ANY table's full schema (incl. select_rule logic) via
--      /rpc/build_schema_for_table, bypassing get_schema's view_permission + existence-hiding.
--      Fix: build_schema_for_table self-gates with the same undefined_table existence-hiding.
--   2. has_consultation was record-scoped, not caller-scoped → any user could probe any record's
--      consultation state via /rpc/has_consultation. Fix: restrict to participants of the
--      governing process; non-participants fail closed (FALSE).
--   3. (LOW) the first-user→Administrator bootstrap over-granted: a batch of users created before
--      anyone logs in (all last_seen NULL) each satisfied "no other user has last_seen" and all
--      became admin. Fix: also require the new row to be created WITH last_seen set.
--
-- Fixtures: user1 = User role only (public:read, NOT admin); user2 = + Northwind Sales (apps/nwind); user3 = admin.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- =====================================================
-- SETUP (admin): an admin-gated entity and a public entity.
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('b9_secret', 'b9_secret', 'Secret', 'Secrets', 'admin-gated entity',
    1, 'admin', 'admin', 'id', 'label');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('b9_public', 'b9_public', 'Public', 'Publics', 'public-read entity',
    1, 'public:read', 'admin', 'id', 'label');

-- admin (holds 'admin') can build the secret schema
SELECT ok(
    public.build_schema_for_table('b9_secret') IS NOT NULL,
    'admin can build_schema_for_table on an admin-gated entity');

-- =====================================================
-- build_schema_for_table self-gating as a non-admin (user1: public:read only)
-- =====================================================
SELECT authenticate_as('user1');

-- user1 lacks 'admin' → must be denied with existence-hiding (undefined_table), NOT given schema
SELECT throws_ok(
    $$SELECT public.build_schema_for_table('b9_secret')$$,
    '42P01',
    NULL,
    'build_schema_for_table denies a no-permission table with undefined_table (no leak)');

-- a non-existent table raises the SAME error → existence cannot be probed
SELECT throws_ok(
    $$SELECT public.build_schema_for_table('b9_does_not_exist')$$,
    '42P01',
    NULL,
    'build_schema_for_table raises the same undefined_table for a missing table (existence-hiding)');

-- user1 DOES hold public:read → can build the public schema
SELECT ok(
    public.build_schema_for_table('b9_public') IS NOT NULL,
    'build_schema_for_table still returns the schema for a table the caller may view');

-- =====================================================
-- has_consultation caller-scope
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO processes (module_id, process_key, name) VALUES (1, 'b9_proc', 'B9 Process');

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'accountable', r.id, 'read'
FROM processes p, roles r WHERE p.process_key = 'b9_proc' AND r.role_name = 'Administrator';

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'consulted', r.id, 'block'
FROM processes p, roles r WHERE p.process_key = 'b9_proc' AND r.role_name = 'Northwind Sales';

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'b9_ent', 'approval', 'done', 'status', FALSE
FROM processes WHERE process_key = 'b9_proc';

-- an ACTED consulted event exists for record '1'
INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
SELECT p.id, 'b9_ent', '1', 'consulted', r.id, 'acted'
FROM processes p, roles r WHERE p.process_key = 'b9_proc' AND r.role_name = 'Northwind Sales';

-- A non-participant (user1: only User role, not assigned to b9_proc) must NOT learn the
-- consultation state — fail closed even though an acted consulted event exists.
SELECT authenticate_as('user1');
SELECT is(
    has_consultation('b9_ent', 'done', '1'),
    FALSE,
    'has_consultation is FALSE for a non-participant (caller-scoped, no existence oracle)');

-- A participant (user2 holds Northwind Sales, the consulted role) gets the real answer.
SELECT authenticate_as('user2');
SELECT is(
    has_consultation('b9_ent', 'done', '1'),
    TRUE,
    'has_consultation returns the true state for a participant in the governing process');

-- =====================================================
-- first-user bootstrap
-- =====================================================
SELECT authenticate_as('user3');

-- Clearing every last_seen produces a state that looks pristine and is not:
-- user3 has held Administrator since the seed. A bootstrap keyed on "has any
-- other user been seen" reads this as "nobody has arrived yet" and elects the
-- next principal created with a last_seen, on top of the administrator already
-- in place. The gate is the role, so neither insert below is elected.
-- 0210_test_first_user_get_userinfo.sql owns the whole rule and
-- 0370_test_last_administrator.sql owns the guard that keeps the role held.
UPDATE users SET last_seen = NULL;

-- A user created WITHOUT last_seen has not arrived and is never elected.
INSERT INTO users (external_id, email, display_name, last_seen)
VALUES ('b9_newbie', 'b9_newbie@test.com', 'Newbie', NULL);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'b9_newbie' AND ur.role_id = 2),
    0,
    'a user created without last_seen does NOT auto-receive Administrator');

-- A user created WITH last_seen has arrived, and is still not elected: the role
-- is taken. This is the assertion that separates the two gates.
INSERT INTO users (external_id, email, display_name, last_seen)
VALUES ('b9_boss', 'b9_boss@test.com', 'Boss', CURRENT_TIMESTAMP);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'b9_boss' AND ur.role_id = 2),
    0,
    'a user created with last_seen is NOT elected while an administrator exists');

SELECT * FROM finish();
ROLLBACK;
