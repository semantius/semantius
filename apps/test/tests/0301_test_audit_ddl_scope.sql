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
--   6. track_ddl_changes carries a tag allowlist that still admits the tags
--      0300 asserts on
--   7. query_text is bounded to 8192 characters
--   8. generated *_label companion functions produce no audit rows
--
-- The NOTIFY half of the same change (pgrst_ddl_watch's schema filter) is NOT
-- testable here: pgTAP runs inside a transaction that rolls back, and a
-- notification is only queued at COMMIT, so there is nothing to observe. It is
-- asserted in pgdocker/pg-ext-lifecycle.sh, where sessions commit for real.
BEGIN;

SELECT plan(12);

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
-- The regression guard for 0300's three count(*) > 0 assertions, and the guard
-- that the new WHEN TAG list did not drop a wanted event.

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
-- TEST 6: the event trigger carries a tag allowlist
-- =====================================================

SELECT ok(
    (SELECT evttags IS NOT NULL FROM pg_event_trigger WHERE evtname = 'track_ddl_changes'),
    'track_ddl_changes fires only for an explicit tag list'
);

SELECT ok(
    (SELECT evttags @> ARRAY['CREATE TABLE', 'CREATE INDEX', 'CREATE TRIGGER',
                             'ALTER TABLE', 'CREATE FUNCTION', 'CREATE POLICY',
                             'GRANT', 'REVOKE', 'COMMENT']
       FROM pg_event_trigger WHERE evtname = 'track_ddl_changes'),
    'the tag list still admits every tag 0300 and the migrations rely on'
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

SELECT * FROM finish();
ROLLBACK;
