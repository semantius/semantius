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
-- Fixtures: user1 = User role only (public:read, NOT admin); user2 = + Sales User; user3 = admin.
BEGIN;

SELECT plan(8);

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
FROM processes p, roles r WHERE p.process_key = 'b9_proc' AND r.role_name = 'Sales User';

INSERT INTO process_gates (process_id, entity, gate_kind, to_state, state_column, emits_events)
SELECT id, 'b9_ent', 'approval', 'done', 'status', FALSE
FROM processes WHERE process_key = 'b9_proc';

-- an ACTED consulted event exists for record '1'
INSERT INTO raci_events (process_id, entity, record_id, raci, target_role_id, status)
SELECT p.id, 'b9_ent', '1', 'consulted', r.id, 'acted'
FROM processes p, roles r WHERE p.process_key = 'b9_proc' AND r.role_name = 'Sales User';

-- A non-participant (user1: only User role, not assigned to b9_proc) must NOT learn the
-- consultation state — fail closed even though an acted consulted event exists.
SELECT authenticate_as('user1');
SELECT is(
    has_consultation('b9_ent', 'done', '1'),
    FALSE,
    'has_consultation is FALSE for a non-participant (caller-scoped, no existence oracle)');

-- A participant (user2 holds Sales User, the consulted role) gets the real answer.
SELECT authenticate_as('user2');
SELECT is(
    has_consultation('b9_ent', 'done', '1'),
    TRUE,
    'has_consultation returns the true state for a participant in the governing process');

-- =====================================================
-- first-user bootstrap hardening (LOW)
-- =====================================================
SELECT authenticate_as('user3');

-- Simulate a pristine system: no user has ever been seen.
UPDATE users SET last_seen = NULL;

-- A user created WITHOUT last_seen must NOT auto-become Administrator (the over-grant fix).
INSERT INTO users (external_id, email, display_name, last_seen)
VALUES ('b9_newbie', 'b9_newbie@test.com', 'Newbie', NULL);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'b9_newbie' AND ur.role_id = 2),
    0,
    'a user created without last_seen does NOT auto-receive Administrator (no over-grant)');

-- A user genuinely accessing the system first (created WITH last_seen, none seen before) DOES.
INSERT INTO users (external_id, email, display_name, last_seen)
VALUES ('b9_boss', 'b9_boss@test.com', 'Boss', CURRENT_TIMESTAMP);

SELECT is(
    (SELECT count(*)::int FROM user_roles ur
     JOIN users u ON u.id = ur.user_id
     WHERE u.external_id = 'b9_boss' AND ur.role_id = 2),
    1,
    'the genuine first-accessing user (created with last_seen) still becomes Administrator');

SELECT * FROM finish();
ROLLBACK;
