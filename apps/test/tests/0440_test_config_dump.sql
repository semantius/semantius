-- =====================================================
-- pg_dump registration and audit silencing (0440)
-- =====================================================
-- Pins release-review items B1 and B3 on the extension install:
--   1. every member table and sequence of pg_semantius is registered with
--      pg_extension_config_dump, or is one of the documented transients
--      (the list below mirrors CONFIG_DUMP_EXCLUDED in
--      packages/cli/commands/extension-dump.ts);
--   2. the registered conditions leave out exactly the rows the install
--      script seeds (CREATE EXTENSION re-creates them on the restore side),
--      keep everything else, and evaluate under pg_dump's
--      search_path = pg_catalog;
--   3. pg_semantius.skip_audit silences the audit triggers in a superuser
--      session (the install script and the documented restore rely on it).
-- On the migrate path there is no extension and every table dumps normally,
-- so groups 1 and 2 report as skipped; group 3 needs a superuser session.
-- The round trip itself is proven by pgdocker/pg-ext-dump-restore.sh.
BEGIN;

SELECT plan(33);

CREATE TEMP TABLE dump_ctx AS
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_semantius') AS ext,
       (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) AS su;

-- Documented transients, never dumped (keep in sync with CONFIG_DUMP_EXCLUDED).
CREATE TEMP TABLE dump_transient (rel) AS VALUES
    ('common._cache'), ('common._cache_id_seq'),
    ('pgmq.notify_insert_throttle'),
    ('pgmq.q_raci_notify'), ('pgmq.q_raci_notify_msg_id_seq'), ('pgmq.a_raci_notify');

-- Every table and sequence that belongs to the extension.
CREATE TEMP VIEW dump_members AS
SELECT n.nspname || '.' || c.relname AS rel, c.relkind,
       c.oid = ANY (COALESCE(e.extconfig, '{}')) AS registered
  FROM pg_depend d
  JOIN pg_extension e ON e.oid = d.refobjid
  JOIN pg_class c ON c.oid = d.objid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE d.classid = 'pg_class'::regclass
   AND d.refclassid = 'pg_extension'::regclass
   AND d.deptype = 'e'
   AND e.extname = 'pg_semantius'
   AND c.relkind IN ('r', 'p', 'S');

-- What is registered, with its pg_dump condition.
CREATE TEMP VIEW dump_config AS
SELECT n.nspname || '.' || k.relname AS rel, k.relkind, cfg.condition
  FROM pg_extension e
  CROSS JOIN LATERAL unnest(e.extconfig, e.extcondition) AS cfg(relid, condition)
  JOIN pg_class k ON k.oid = cfg.relid
  JOIN pg_namespace n ON n.oid = k.relnamespace
 WHERE e.extname = 'pg_semantius';

-- Rows pg_dump would emit for a registered table, optionally narrowed by an
-- extra predicate. Runs with pg_dump's search_path, so an unqualified
-- reference in a condition raises here exactly as it would in pg_dump.
CREATE FUNCTION pg_temp.dumped(p_rel text, p_extra text DEFAULT '')
RETURNS bigint LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    v_cond  text;
    v_count bigint;
BEGIN
    SELECT cfg.condition INTO v_cond
      FROM pg_catalog.pg_extension e
      CROSS JOIN LATERAL unnest(e.extconfig, e.extcondition) AS cfg(relid, condition)
     WHERE e.extname = 'pg_semantius' AND cfg.relid = p_rel::regclass;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not registered with pg_extension_config_dump', p_rel;
    END IF;
    -- The registered condition is parenthesised: several contain OR.
    EXECUTE format('SELECT count(*) FROM %s %s', p_rel,
                   CASE WHEN p_extra = '' THEN v_cond
                        WHEN v_cond = '' THEN 'WHERE ' || p_extra
                        ELSE 'WHERE (' || regexp_replace(v_cond, '^\s*WHERE\s+', '', 'i')
                             || ') AND (' || p_extra || ')' END)
       INTO v_count;
    RETURN v_count;
END $$;

-- Every registered table condition, evaluated the way pg_dump evaluates it.
-- Returns the failures (relation: error), or NULL when all of them run.
CREATE FUNCTION pg_temp.condition_errors()
RETURNS text LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
    cfg      record;
    v_n      bigint;
    v_errors text[] := '{}';
BEGIN
    FOR cfg IN
        SELECT c.relid::regclass AS rel, c.condition
          FROM pg_catalog.pg_extension e
          CROSS JOIN LATERAL unnest(e.extconfig, e.extcondition) AS c(relid, condition)
          JOIN pg_catalog.pg_class k ON k.oid = c.relid
         WHERE e.extname = 'pg_semantius' AND k.relkind IN ('r', 'p')
    LOOP
        BEGIN
            EXECUTE format('SELECT count(*) FROM %s %s', cfg.rel, cfg.condition) INTO v_n;
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors || (cfg.rel::text || ': ' || SQLERRM);
        END;
    END LOOP;
    RETURN NULLIF(array_to_string(v_errors, '; '), '');
END $$;

-- =====================================================
-- GROUP 1: registration is complete
-- =====================================================

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is((SELECT string_agg(rel, ', ' ORDER BY rel COLLATE "C") FROM dump_members
         WHERE NOT registered AND rel NOT IN (SELECT rel FROM dump_transient)),
       NULL::text,
       'every member table and sequence is registered with pg_extension_config_dump or listed as transient')
ELSE pass('migrate path (no extension): registration check skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is((SELECT string_agg(t.rel, ', ' ORDER BY t.rel COLLATE "C") FROM dump_transient t
         WHERE NOT EXISTS (SELECT 1 FROM dump_members m WHERE m.rel = t.rel)),
       NULL::text,
       'every listed transient is still a member relation (the list is not stale)')
ELSE pass('migrate path (no extension): transient list check skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is((SELECT string_agg(m.rel, ', ' ORDER BY m.rel COLLATE "C") FROM dump_members m
         WHERE m.registered AND m.rel IN (SELECT rel FROM dump_transient)),
       NULL::text,
       'no transient relation is registered for pg_dump')
ELSE pass('migrate path (no extension): transient registration check skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.condition_errors(), NULL::text,
       'every registered condition runs with search_path = pg_catalog (references are schema-qualified)')
ELSE pass('migrate path (no extension): condition evaluation check skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is((SELECT string_agg(rel, ', ' ORDER BY rel COLLATE "C") FROM dump_config
         WHERE relkind IN ('r', 'p') AND condition = ''),
       'pgmq.topic_bindings, public._apikeys, public.audit_ddl_logs, public.audit_record_logs, '
       'public.dashboards, public.process_gates, public.processes, public.raci_assignments, '
       'public.raci_events, public.user_bookmarks, public.user_permissions, public.user_roles, '
       'public.users, public.webhook_receiver_logs, public.webhook_receivers',
       'the user-data tables are dumped in full')
ELSE pass('migrate path (no extension): full-dump list check skipped') END;

-- =====================================================
-- GROUP 2: the conditions leave out the seeded rows and keep the rest
-- =====================================================
-- The nwind module, its permissions, role, entities, fields and queue are the
-- "user data" fixture (deno task migrate --apps _core,nwind,test).

INSERT INTO _settings (name, value) VALUES ('dump_probe', 'x');

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.modules', 'id = 1'), 0::bigint, 'modules: the _core module is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.modules', 'module_slug = ''nwind'''), 1::bigint, 'modules: a user module is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.permissions', 'id < 10000'), 0::bigint, 'permissions: the seeded permissions are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.permissions', 'permission_name = ''nwind:view'''), 1::bigint, 'permissions: a module permission is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.roles', 'id < 10000'), 0::bigint, 'roles: the seeded roles are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.roles', 'slug = ''northwind_sales'''), 1::bigint, 'roles: a module role is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.permission_hierarchy', 'including_permission_id < 10000 AND included_permission_id < 10000'), 0::bigint,
       'permission_hierarchy: the seeded pair is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.permission_hierarchy'),
       (SELECT count(*) FROM permission_hierarchy WHERE including_permission_id >= 10000 OR included_permission_id >= 10000),
       'permission_hierarchy: every pair that involves a module permission is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.role_permissions', 'role_id < 10000 AND permission_id < 10000'), 0::bigint,
       'role_permissions: the seeded pairs are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.role_permissions', 'role_id = 2 AND permission_id >= 10000'),
       (SELECT count(*) FROM role_permissions WHERE role_id = 2 AND permission_id >= 10000),
       'role_permissions: the auto-grants of module permissions to Administrator are dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.entities', 'module_id = 1'), 0::bigint, 'entities: the core entities are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.entities', 'table_name = ''customers'''), 1::bigint, 'entities: a module entity is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.fields', 'table_name IN (SELECT table_name FROM public.entities WHERE module_id = 1)'), 0::bigint,
       'fields: the fields of the core entities are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.fields', 'table_name = ''customers'''),
       (SELECT count(*) FROM fields WHERE table_name = 'customers'),
       'fields: every field of a module entity is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public._settings', 'name = ''db_version'''), 0::bigint, '_settings: db_version is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public._settings', 'name = ''dump_probe'''), 1::bigint, '_settings: every other setting is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public._versions', 'left(name, 6) = ''_core.'''), 0::bigint, '_versions: the _core guards are not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public._versions', 'name = ''nwind.0010_create'''), 1::bigint, '_versions: other apps'' guards are dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('pgmq.meta', 'queue_name = ''raci_notify'''), 0::bigint, 'pgmq.meta: the raci_notify queue is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('pgmq.meta', 'queue_name = ''events'''), 1::bigint, 'pgmq.meta: a user queue is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.queues', 'queue_name = ''raci_notify'''), 0::bigint, 'queues: the raci_notify queue definition is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.queues', 'queue_name = ''events'''), 1::bigint, 'queues: a user queue definition is dumped')
ELSE pass('migrate path: skipped') END;

SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.queue_table_events', 'table_name = ''raci_events'''), 0::bigint,
       'queue_table_events: the raci_events wiring to raci_notify is not dumped')
ELSE pass('migrate path: skipped') END;
SELECT CASE WHEN (SELECT ext FROM dump_ctx) THEN
    is(pg_temp.dumped('public.queue_table_events', 'queue_id IN (SELECT id FROM public.queues WHERE queue_name = ''events'')'),
       (SELECT count(*) FROM queue_table_events WHERE queue_id IN (SELECT id FROM queues WHERE queue_name = 'events')),
       'queue_table_events: the wiring of a user queue is dumped')
ELSE pass('migrate path: skipped') END;

-- =====================================================
-- GROUP 3: pg_semantius.skip_audit (superuser sessions only)
-- =====================================================
-- The extension script sets it for the install, the documented restore sets
-- it through PGOPTIONS. A request role cannot use it: session_user is the
-- login role and never a superuser for application sessions (SET ROLE does
-- not change it), which is also why the negative case cannot run inside
-- this suite.

SELECT authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column, audit_log
) VALUES (
    'skip_audit_probe', 'probe', 'Skip Audit Probe', 'Skip Audit Probes',
    'Probe entity for the audit silencing setting',
    1, 'public:read', 'admin', 'id', 'probe_name', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width)
VALUES ('skip_audit_probe', 'status', 'Status', 'text', 10, 'default', 'default');

-- Silenced.
SET LOCAL pg_semantius.skip_audit = on;
INSERT INTO skip_audit_probe (probe_name, status) VALUES ('silenced', 'x');
RESET ROLE;
CREATE TABLE public.skip_audit_ddl_probe (id int);

SELECT CASE WHEN (SELECT su FROM dump_ctx) THEN
    is((SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'skip_audit_probe'), 0,
       'skip_audit = on: a row insert writes no audit row')
ELSE pass('not a superuser session: skip_audit check skipped') END;
SELECT CASE WHEN (SELECT su FROM dump_ctx) THEN
    is((SELECT count(*)::int FROM audit_ddl_logs WHERE object_identity LIKE '%skip_audit_ddl_probe%'), 0,
       'skip_audit = on: DDL writes no audit row')
ELSE pass('not a superuser session: skip_audit check skipped') END;

-- Back to normal.
SET LOCAL pg_semantius.skip_audit = off;
SELECT authenticate_as('user3');
INSERT INTO skip_audit_probe (probe_name, status) VALUES ('audited', 'y');
RESET ROLE;
ALTER TABLE public.skip_audit_ddl_probe ADD COLUMN note text;

SELECT CASE WHEN (SELECT su FROM dump_ctx) THEN
    is((SELECT count(*)::int FROM audit_record_logs WHERE table_name = 'skip_audit_probe' AND op = 'INSERT'), 1,
       'skip_audit = off: the row insert is audited again')
ELSE pass('not a superuser session: skip_audit check skipped') END;
SELECT CASE WHEN (SELECT su FROM dump_ctx) THEN
    ok((SELECT count(*) FROM audit_ddl_logs WHERE object_identity LIKE '%skip_audit_ddl_probe%') > 0,
       'skip_audit = off: DDL is audited again')
ELSE pass('not a superuser session: skip_audit check skipped') END;

SELECT * FROM finish();
ROLLBACK;
