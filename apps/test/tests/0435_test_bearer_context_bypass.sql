-- =====================================================
-- Bearer-session context bypass and derived user id (0435)
-- =====================================================
-- Release review S2: the transaction-scoped context cache (the app.* settings
-- written by rbac.ensure_context_initialized) is client-writable. Behind
-- PostgREST or an app server that is harmless, because the client never runs
-- SQL. A PostgreSQL 18 OAuth bearer session (system_user = 'oauth:<sub>') does
-- run SQL as the request role, so for such sessions ensure_context_initialized
-- no longer trusts the cache and re-derives the context on every call.
--
-- pgTAP cannot open a bearer session (system_user cannot be faked), so this
-- file pins the parts that are testable here:
--   * the detector is false for SCRAM/local sessions and whoami says so,
--   * rbac.user_id_or_null() is NULL without a JWT and the user's id with one,
--   * the two readers that used to take app.current_user_id raw
--     (audit.current_user_id and the generated compute/validate trigger) go
--     through rbac now: they resolve the user even when nothing initialized
--     the context before the write, and a hand-written app.current_user_id
--     does not reach them.
BEGIN;

SELECT plan(11);

-- =====================================================
-- GROUP 1: no authenticated context (DBA session, no JWT)
-- =====================================================
SELECT is(rbac.is_bearer_session(), false,
    'is_bearer_session: a SCRAM/local DBA session is not a bearer session');
SELECT is(rbac.user_id_or_null(), NULL,
    'user_id_or_null: NULL without a JWT');
SELECT is(audit.current_user_id(), 0,
    'audit.current_user_id: 0 without a JWT');

-- =====================================================
-- GROUP 2: authenticated as user3 (Administrator)
-- =====================================================
SELECT authenticate_as('user3');

SELECT is(rbac.is_bearer_session(), false,
    'is_bearer_session: still false after SET ROLE in a SCRAM session');
SELECT is(rbac.user_id_or_null(), 1003,
    'user_id_or_null: the internal id of the authenticated user');
SELECT is((SELECT value FROM rbac.whoami() WHERE context_type = 'status' AND key = 'permission_cache'),
    'enabled', 'whoami: the permission cache is enabled outside bearer sessions');

-- =====================================================
-- GROUP 3: the compute/validate trigger derives $user_id through rbac
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column,
    computed_fields)
VALUES ('bearer_probe', 'bearer_probe', 'Probe', 'Probes', 'S2 user-id probe',
    1, 'public:read', 'admin', 'id', 'label',
    '[{"name": "writer_id", "jsonlogic": {"var": "$user_id"}}]'::jsonb);

INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('bearer_probe', 'writer_id', 'Writer Id', 'integer', 10);

-- Nothing initialized the context before this write: the trigger has to derive it.
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_user_id', '', true);
INSERT INTO bearer_probe (label) VALUES ('first statement');
SELECT is((SELECT writer_id FROM bearer_probe WHERE label = 'first statement'), 1003,
    '$user_id: derived on the first statement of an uninitialized context');

-- A hand-written app.current_user_id without an initialized context is ignored.
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_user_id', '1002', true);
INSERT INTO bearer_probe (label) VALUES ('forged setting');
SELECT is((SELECT writer_id FROM bearer_probe WHERE label = 'forged setting'), 1003,
    '$user_id: a hand-written app.current_user_id is not read raw');

-- =====================================================
-- GROUP 4: audit.current_user_id derives the user the same way
-- =====================================================
-- audit.current_user_id is not executable by semantius_user; call it as the
-- DBA while the JWT claims set by authenticate_as are still in effect.
RESET ROLE;
SELECT set_config('app.context_initialized', '', true);
SELECT set_config('app.current_user_id', '1002', true);
SELECT is(audit.current_user_id(), 1003,
    'audit.current_user_id: derived from the JWT, not from app.current_user_id');
SELECT is(rbac.user_id_or_null(), 1003,
    'user_id_or_null: unaffected by a hand-written app.current_user_id');
SELECT is(current_setting('app.current_user_id', true), '1003',
    'ensure_context_initialized: the rebuild overwrote the hand-written value');

DELETE FROM entities WHERE table_name = 'bearer_probe';

SELECT * FROM finish();
ROLLBACK;
