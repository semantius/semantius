-- SECURITY DEFINER read helpers must authorize like RLS does: honor
-- select_rule, and check permissions on every entry point.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. get_record_by_id honors select_rule
--   2. Read-helper completeness
--   3. get_record_by_id over an is_a chain
--   4. get_record_by_id in a privileged direct session
BEGIN;

SELECT plan(18);

-- =====================================================
-- PART 1: get_record_by_id honors select_rule
-- =====================================================
-- SECURITY DEFINER read helpers must honor select_rule, not just view_permission.
--
--   get_record_by_id() is SECURITY DEFINER (bypasses RLS). When an entity has a select_rule,
--   the RLS SELECT policy uses the RULE (REPLACE semantics); a helper that authorized on
--   view_permission alone would let any holder of view_permission (commonly public:read, which
--   EVERY user has) read a row the select_rule hides, one id at a time. get_record_by_id
--   applies access(row) (0160_dd_functions.sql). The set_record JsonLogic operator and
--   /rpc/evaluate_json_logic wrap this same primitive.
--
-- Per docs/authorization.md the canonical predicate access(row) MUST be enforced
-- identically in the SELECT policy, the DEFINER read helpers, and the write USING clauses.
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
-- The other read helpers that authorize on their own (docs/authorization.md D10, I8 and I5):
--
--   1. build_schema_for_table is GRANTed to the request role and reachable as
--      /rpc/build_schema_for_table. It checks view_permission itself, raising undefined_table
--      when it is not held: without that check any public:read holder would read ANY table's
--      full schema (incl. select_rule logic) there, around get_schema's view_permission check.
--   2. has_consultation answers per caller, not per record: only participants of the governing
--      process get an answer, non-participants fail closed (FALSE). Answered per record, any
--      user could probe any record's consultation state via /rpc/has_consultation.
--   3. The first-user→Administrator bootstrap requires the new row to be created WITH last_seen
--      set. Otherwise a batch of users created before anyone logs in (all last_seen NULL) would
--      each satisfy "no other user has last_seen", and all would become admin.
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
VALUES ('rh_secret', 'rh_secret', 'Secret', 'Secrets', 'admin-gated entity',
    1, 'admin', 'admin', 'id', 'label');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('rh_public', 'rh_public', 'Public', 'Publics', 'public-read entity',
    1, 'public:read', 'admin', 'id', 'label');

-- admin (holds 'admin') can build the secret schema
SELECT ok(
    public.build_schema_for_table('rh_secret') IS NOT NULL,
    'admin can build_schema_for_table on an admin-gated entity');

-- =====================================================
-- build_schema_for_table self-gating as a non-admin (user1: public:read only)
-- =====================================================
SELECT authenticate_as('user1');

-- user1 lacks 'admin' → must be denied (undefined_table), NOT given schema
SELECT throws_ok(
    $$SELECT public.build_schema_for_table('rh_secret')$$,
    '42P01',
    NULL,
    'build_schema_for_table denies a no-permission table with undefined_table');

-- a non-existent table raises undefined_table as well
SELECT throws_ok(
    $$SELECT public.build_schema_for_table('rh_does_not_exist')$$,
    '42P01',
    NULL,
    'build_schema_for_table raises undefined_table for a missing table');

-- user1 DOES hold public:read → can build the public schema
SELECT ok(
    public.build_schema_for_table('rh_public') IS NOT NULL,
    'build_schema_for_table still returns the schema for a table the caller may view');

-- =====================================================
-- has_consultation caller-scope
-- =====================================================
SELECT authenticate_as('user3');

INSERT INTO processes (module_id, process_key, name) VALUES (1, 'rh_proc', 'Read Helper Process');

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'accountable', r.id, 'read'
FROM processes p, roles r WHERE p.process_key = 'rh_proc' AND r.role_name = 'Administrator';

INSERT INTO raci_assignments (process_id, raci, role_id, consult_mode)
SELECT p.id, 'consulted', r.id, 'block'
FROM processes p, roles r WHERE p.process_key = 'rh_proc' AND r.role_name = 'Northwind Sales';

-- A gate names an entity (a foreign key), so the governed entity exists first.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('rh_ent', 'Read Helper Entity', 'Read Helper Entities', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rh_ent', 'status', 'Status', 'text', 20);

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'rh_ent', 'approval', 'done', 'status', FALSE
FROM processes WHERE process_key = 'rh_proc';

-- an ACTED consulted event exists for record '1'
INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
SELECT p.id, 'rh_ent', '1', 'consulted', r.id, 'acted'
FROM processes p, roles r WHERE p.process_key = 'rh_proc' AND r.role_name = 'Northwind Sales';

-- A non-participant (user1: only User role, not assigned to rh_proc) must NOT learn the
-- consultation state — fail closed even though an acted consulted event exists.
SELECT authenticate_as('user1');
SELECT is(
    has_consultation('rh_ent', 'done', '1'),
    FALSE,
    'has_consultation is FALSE for a non-participant (caller-scoped, no existence oracle)');

-- A participant (user2 holds Northwind Sales, the consulted role) gets the real answer.
SELECT authenticate_as('user2');
SELECT is(
    has_consultation('rh_ent', 'done', '1'),
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
VALUES ('rh_newbie', 'rh_newbie@test.com', 'Newbie', NULL);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'rh_newbie' AND ur.role_id = 2),
    0,
    'a user created without last_seen does NOT auto-receive Administrator');

-- A user created WITH last_seen has arrived, and is still not elected: the role
-- is taken. This is the assertion that separates the two gates.
INSERT INTO users (external_id, email, display_name, last_seen)
VALUES ('rh_boss', 'rh_boss@test.com', 'Boss', CURRENT_TIMESTAMP);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'rh_boss' AND ur.role_id = 2),
    0,
    'a user created with last_seen is NOT elected while an administrator exists');

-- =====================================================
-- PART 3: get_record_by_id over an is_a chain
-- =====================================================
-- A record of rh_hot (is_a rh_leads, is_a rh_parties) is stored in three
-- tables. get_record_by_id reads it through the view and applies the
-- canonical predicate of every level, which is what the security_invoker
-- view gives the same caller under RLS.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, view_permission)
VALUES ('rh_parties', 'Party', 'Parties', 1, 'typeid', 'rhpty', 'public:read');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rh_parties', 'region', 'Region', 'text', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity, view_permission)
VALUES ('rh_leads', 'Lead', 'Leads', 1, 'is_a', 'rhled', 'rh_parties', 'nwind:view');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rh_leads', 'score', 'Score', 'int32', 30);
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, id_prefix, id_refentity,
                      view_permission, select_rule)
VALUES ('rh_hot', 'Hot Lead', 'Hot Leads', 1, 'is_a', 'rhhot', 'rh_leads', 'public:read',
        '{"==":[{"var":"region"},"north"]}'::jsonb);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('rh_hot', 'heat', 'Heat', 'int32', 30);

INSERT INTO rh_hot (label, region, score, heat) VALUES ('h1', 'north', 1, 90), ('h2', 'south', 2, 80);

SELECT is(
    (SELECT get_record_by_id('rh_hot', (SELECT id FROM rh_hot WHERE label = 'h1')) ->> 'region')
    || ' ' || (SELECT get_record_by_id('rh_hot', (SELECT id FROM rh_hot WHERE label = 'h1')) ->> 'heat'),
    'north 90',
    'get_record_by_id: a three-level record comes back whole, root fields included');

SELECT authenticate_as('user2');
SELECT ok(
    get_record_by_id('rh_hot', (SELECT id::text FROM rh_parties WHERE label = 'h1')) IS NOT NULL
    AND get_record_by_id('rh_hot', (SELECT id::text FROM rh_parties WHERE label = 'h2')) IS NULL,
    'get_record_by_id: the select_rule of a level decides, over the whole record');

SELECT authenticate_as('user1');
SELECT is(
    get_record_by_id('rh_hot', (SELECT id::text FROM rh_parties WHERE label = 'h1')),
    NULL,
    'get_record_by_id: without the view permission of a middle level the record is not found');

SELECT is(
    (SELECT count(*)::int FROM rh_hot),
    0,
    'get_record_by_id: ... which is what the view gives the same caller');

-- =====================================================
-- PART 4: get_record_by_id in a privileged direct session
-- =====================================================
-- The runner logs in as the BYPASSRLS owner, like a migration. With no SET
-- ROLE and no claims, get_record_by_id reads unchecked, which is what lets a
-- migration seed records whose computed fields use set_record. Claims, or a
-- switch to the request role, put the same login back under the checks.
-- products is the nwind sample table; user1 lacks nwind:view.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;
-- authenticate_as set the claims transaction-locally; '' is what such a
-- setting reads back as once cleared, and counts as no claim.
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.' || k, '', true)
       FROM unnest(ARRAY['sub', 'email', 'name', 'given_name', 'family_name', 'role', 'aud']) k;
END $$;

SELECT is(
    get_record_by_id('products', '11') ->> 'product_name',
    'Queso Cabrales',
    'get_record_by_id: a privileged login with no SET ROLE and no claims reads the row');

SELECT authenticate_as('user1');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    get_record_by_id('products', '11'),
    NULL,
    'get_record_by_id: the same login carrying claims is checked as that user');

DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.' || k, '', true)
       FROM unnest(ARRAY['sub', 'email', 'name', 'given_name', 'family_name', 'role', 'aud']) k;
END $$;
SET LOCAL ROLE semantius_user;
SELECT throws_ok(
    $$ SELECT get_record_by_id('products', '11') $$,
    '42501', NULL,
    'get_record_by_id: the same login after SET ROLE to the request role, without claims, is refused');

SELECT * FROM finish();
ROLLBACK;
