-- Tests for the SCOPE of the DDL audit (audit.log_ddl_event / track_ddl_changes).
--
-- 0300 proves the DDL audit records what it should. This file proves it does
-- NOT record what it should not, and that it no longer blocks the request role:
--
--   1. DDL in a schema Semantius does not own produces no audit row
--   2. DDL in public still does                     (regression guard for 0300)
--   3. CREATE TEMP TABLE produces no audit row
--   4. CREATE TEMP TABLE succeeds as the request role (S15)
--   5. audit.log_ddl_event is SECURITY DEFINER, which is what makes 4 true
--   6. track_ddl_changes carries no tag allowlist: the schema is the scope
--   7. query_text is bounded to 8192 characters
--   8. generated *_label companion functions produce no audit rows
--   9. a command type nobody enumerated is audited all the same
--  10. DROP TABLE in public is audited, once, as the table alone
--  11. DROP TABLE in a foreign schema is not audited
--  12. the label churn's DROP FUNCTION half is not audited either
--  13. audit.log_drop_event is SECURITY DEFINER, for the reason 5 gives
--
-- The NOTIFY half of the same change (pgrst_ddl_watch's schema filter) is NOT
-- testable here: pgTAP runs inside a transaction that rolls back, and a
-- notification is only queued at COMMIT, so there is nothing to observe. It is
-- asserted in pgdocker/pg-ext-lifecycle.sh, where sessions commit for real.
BEGIN;

SELECT plan(17);

-- =====================================================
-- TEST 1: DDL in a non-Semantius schema is not logged
-- =====================================================

CREATE SCHEMA audit_scope_foreign;
CREATE TABLE audit_scope_foreign.t (id int);
CREATE INDEX audit_scope_foreign_t_idx ON audit_scope_foreign.t (id);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE object_identity LIKE 'audit\_scope\_foreign.%'),
    0,
    'DDL in a schema Semantius does not own produces no audit row'
);

-- =====================================================
-- TEST 2: DDL in public is still logged
-- =====================================================
-- The regression guard for 0300's three count(*) > 0 assertions.

CREATE TABLE public.audit_scope_owned (id int);
CREATE INDEX audit_scope_owned_idx ON public.audit_scope_owned (id);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE command_tag = 'CREATE TABLE'
        AND object_identity = 'public.audit_scope_owned'),
    1,
    'CREATE TABLE in public is still logged'
);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE command_tag = 'CREATE INDEX'
        AND object_identity = 'public.audit_scope_owned_idx'),
    1,
    'CREATE INDEX in public is still logged'
);

-- =====================================================
-- TEST 3: temp objects are not logged
-- =====================================================

CREATE TEMP TABLE audit_scope_tmp (id int);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE object_identity LIKE '%audit\_scope\_tmp%'),
    0,
    'CREATE TEMP TABLE produces no audit row'
);

-- =====================================================
-- TEST 4 (S15): the request role can run DDL again
-- =====================================================
-- Before the fix this raised
--   ERROR: permission denied for function current_user_id
-- from audit.log_ddl_event(), because the event trigger ran as the caller and
-- audit.current_user_id() is revoked from PUBLIC.

SELECT authenticate_as('user1');

SELECT lives_ok(
    'CREATE TEMP TABLE audit_scope_tmp_user (id int)',
    'the request role can create a temp table'
);

RESET ROLE;

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE object_identity LIKE '%audit\_scope\_tmp\_user%'),
    0,
    'the request role''s temp table produces no audit row either'
);

-- =====================================================
-- TEST 5: log_ddl_event is SECURITY DEFINER
-- =====================================================
-- The mechanism behind TEST 4, and what makes the three audit triggers
-- consistent (insert_update_delete_trigger and truncate_trigger already were).

SELECT ok(
    (SELECT p.prosecdef
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'audit' AND p.proname = 'log_ddl_event'),
    'audit.log_ddl_event is SECURITY DEFINER'
);

-- =====================================================
-- TEST 6: the event trigger carries no tag allowlist
-- =====================================================
-- The schema is the scope, not the command name. A tag list could only ever be
-- a guess at which commands matter, and the ones left out would pass over an
-- evidence table without a trace. TEST 9 is the same claim from the other side.

SELECT ok(
    (SELECT evttags IS NULL FROM pg_event_trigger WHERE evtname = 'track_ddl_changes'),
    'track_ddl_changes fires for every command type'
);

-- =====================================================
-- TEST 7: query_text is bounded
-- =====================================================
-- current_query() is the whole migration script for script-driven DDL, stored
-- once per event. Unbounded it was 85 MB after a full migrate. This is an
-- upper-bound guard: on the migrate path rows sit at exactly 8192, but on the
-- extension path every install row is the short 'SELECT semantius.migrate()',
-- so the assertion is only non-vacuous on the migrate path. The exact
-- truncation is pinned in pg-ext-lifecycle.sh step 11, which issues a
-- deliberately over-long statement.

SELECT ok(
    (SELECT COALESCE(max(length(query_text)), 0) FROM audit_ddl_logs) <= 8192,
    'query_text is never longer than 8192 characters'
);

-- =====================================================
-- TEST 8: generated label companions are not logged
-- =====================================================
-- rebuild_entity_label_functions (0145) drops and recreates the whole set of
-- <name>_label(rowtype) functions on any field edit. The migrations create
-- dozens of them; none may appear in the audit log.
--
-- The first assertion is what stops the second from being vacuous: it proves
-- the churn actually happened in this database. Note the filter can only reach
-- the CREATE/ALTER FUNCTION and COMMENT events - the matching GRANT and REVOKE
-- events carry a NULL object_identity (and NULL classid/objid/schema_name), so
-- nothing in the event trigger can tell which function they touched.

SELECT ok(
    (SELECT count(*) FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND (p.proname = '_label' OR p.proname LIKE '%\_label')) > 0,
    'the migrations generated *_label companion functions'
);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE object_identity ~ '(^|[.])[^.(]*_label[(]'),
    0,
    'generated *_label functions produce no audit rows'
);

-- =====================================================
-- TEST 9: a command type nobody enumerated is audited
-- =====================================================
-- CREATE STATISTICS was not on the tag list the trigger used to carry, and it
-- changes the planner's behavior on a table Semantius owns. It stands here for
-- every other command type nobody thought to name.

CREATE TABLE public.audit_scope_drop (id serial PRIMARY KEY, label text NOT NULL DEFAULT '');
CREATE INDEX audit_scope_drop_label_idx ON public.audit_scope_drop (label);
CREATE STATISTICS public.audit_scope_stats ON id, label FROM public.audit_scope_drop;

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE command_tag = 'CREATE STATISTICS'
        AND object_identity = 'public.audit_scope_stats'),
    1,
    'a command type the old tag list never named is audited'
);

-- =====================================================
-- TEST 10: DROP TABLE in public is audited, once
-- =====================================================
-- ddl_command_end reports nothing at all for a drop, so this is entirely the
-- work of the sql_drop trigger. PostgreSQL reports the table's whole dependency
-- closure: for this one, measured on PostgreSQL 18, fourteen objects - the
-- table, its sequence, its rowtype, its array type, two column defaults, two
-- not-null constraints, the primary key and its index, the label index, the
-- statistics object, and the TOAST table with its index. Exactly one of them is
-- the object the operator named.
--
-- The assertion reads every row the DROP added rather than rows matching the
-- table's name, and that is the point: a name filter cannot see the constraint
-- rows (they are identified as "<name> on public.<table>") or the TOAST pair,
-- so it would still pass with the `original` filter deleted.

CREATE TEMP TABLE audit_scope_drop_mark AS
SELECT coalesce(max(id), 0) AS id FROM audit_ddl_logs;

DROP TABLE public.audit_scope_drop;

SELECT is(
    (SELECT coalesce(string_agg(command_tag || ' ' || object_type || ' ' || object_identity, ', ' ORDER BY id), '')
       FROM audit_ddl_logs
      WHERE id > (SELECT id FROM audit_scope_drop_mark)),
    'DROP TABLE table public.audit_scope_drop',
    'DROP TABLE in public logs one row, the table, and nothing else the statement dropped'
);

-- =====================================================
-- TEST 11: DROP TABLE in a foreign schema is not audited
-- =====================================================
-- The mirror of TEST 1 for the drop side: the schema filter is what bounds the
-- new trigger too, and audit_scope_foreign.t comes from TEST 1.

DROP TABLE audit_scope_foreign.t;

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE object_identity LIKE 'audit\_scope\_foreign.%'),
    0,
    'DROP TABLE in a schema Semantius does not own produces no audit row'
);

-- =====================================================
-- TEST 12: the label churn's DROP FUNCTION half is not audited
-- =====================================================
-- rebuild_entity_label_functions (0145) drops every label companion of an
-- entity before recreating it, on every field edit. TEST 8 keeps that churn out
-- of the log on the create side; without the same filter on the drop side it
-- would all come back in through the sql_drop trigger.
--
-- The companion is dropped explicitly rather than by provoking a rebuild. A
-- rebuild fires only for edits to a field's name, format or reference_table, so
-- a test that edits some other column proves nothing and does not say so; doing
-- the drop directly is the event under test, and the first assertion is what
-- stops the second from being vacuous.

SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('audit_scope_lbl', 'audit_scope_lbl', 'Audit Scope Label', 'Audit Scope Labels', 'label churn probe', 1, 'public:read', 'admin', 'id', 'label');

RESET ROLE;

SELECT ok(
    to_regprocedure('public._label(public.audit_scope_lbl)') IS NOT NULL,
    'the entity generated a *_label companion there is something to drop'
);

DROP FUNCTION public._label(public.audit_scope_lbl);

SELECT is(
    (SELECT count(*)::integer FROM audit_ddl_logs
      WHERE command_tag = 'DROP FUNCTION'
        AND object_identity ~ '(^|[.])[^.(]*_label[(]'),
    0,
    'dropping a generated *_label companion produces no audit row'
);

-- =====================================================
-- TEST 13: log_drop_event is SECURITY DEFINER
-- =====================================================
-- Same reason as TEST 5: audit.current_user_id() is revoked from PUBLIC, so a
-- caller-rights trigger would make DROP TABLE fail for the request role - and
-- the request role does drop things, its own temp tables among them.

SELECT ok(
    (SELECT p.prosecdef
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'audit' AND p.proname = 'log_drop_event'),
    'audit.log_drop_event is SECURITY DEFINER'
);

SELECT * FROM finish();
ROLLBACK;
