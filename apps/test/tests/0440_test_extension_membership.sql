-- =====================================================
-- Extension membership invariants (0440)
-- =====================================================
-- The pg_semantius extension is a THIN INSTALLER: `CREATE EXTENSION` creates
-- only the cluster roles, the `semantius` schema and that schema's functions,
-- and `SELECT semantius.migrate()` then installs the core schema as ORDINARY
-- objects. This file pins the properties that whole design rests on:
--
--   1. membership: the ONLY members are the schema and its functions, and
--      nothing in the five core schemas belongs to any extension;
--   2. no `pg_extension_config_dump` registry (extconfig IS NULL) - there are
--      no member tables whose rows would need registering;
--   3. the control-file pinning: schema `public`, not relocatable;
--   4. the installer functions are locked down (no PUBLIC EXECUTE, not
--      SECURITY DEFINER, pinned search_path, commented) and the schema is not
--      world-usable;
--   5. `_versions` matches the bundle exactly and `pending()` is empty;
--   6. a non-superuser cannot run migrate();
--   7. `pg_semantius.skip_audit` no longer silences anything (it was a
--      workaround for member tables and was removed with them);
--   8. `DROP EXTENSION` is inert: it takes the schema and its functions and
--      leaves every table, row, trigger, policy and event trigger behind.
--
-- On the migrate path there is no extension, so groups 1-6 report as skipped.
-- The dump/restore round trip itself is proven by pgdocker/pg-ext-lifecycle.sh.
BEGIN;

SELECT plan(29);

CREATE TEMP TABLE ext_ctx AS
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_semantius') AS ext,
       (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) AS su;

-- `semantius.pending()` and `semantius.version()` are resolved when the
-- statement is PARSED, not when a CASE branch is taken, so referencing them
-- directly would make this whole file fail to parse on the migrate path, where
-- the schema does not exist. These wrappers defer resolution to EXECUTE.
CREATE FUNCTION pg_temp.ext_pending() RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius') THEN
    RETURN -1;
  END IF;
  EXECUTE 'SELECT count(*)::int FROM semantius.pending()' INTO n;
  RETURN n;
END
$fn$;

CREATE FUNCTION pg_temp.ext_version() RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius') THEN
    RETURN NULL;
  END IF;
  EXECUTE 'SELECT semantius.version()' INTO v;
  RETURN v;
END
$fn$;

-- -----------------------------------------------------------------------
-- GROUP 1: membership
-- -----------------------------------------------------------------------

-- Every object that belongs to pg_semantius, by catalog.
CREATE TEMP VIEW ext_members AS
SELECT d.classid::regclass::text AS catalog, count(*)::int AS n
  FROM pg_depend d
  JOIN pg_extension e ON e.oid = d.refobjid
 WHERE d.refclassid = 'pg_extension'::regclass
   AND d.deptype = 'e'
   AND e.extname = 'pg_semantius'
 GROUP BY 1;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM ext_members WHERE catalog = 'pg_class'), 0,
       'no relation is a member of pg_semantius')
ELSE pass('migrate path (no extension): relation membership check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT coalesce(n, 0) FROM ext_members WHERE catalog = 'pg_namespace'), 1,
       'exactly one schema is a member of pg_semantius')
ELSE pass('migrate path (no extension): schema membership check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT string_agg(n.nspname, ',') FROM pg_depend d
          JOIN pg_extension e ON e.oid = d.refobjid
          JOIN pg_namespace n ON n.oid = d.objid
         WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
           AND d.classid = 'pg_namespace'::regclass AND e.extname = 'pg_semantius'),
       'semantius',
       'the member schema is "semantius" (pg_ is reserved for system schemas)')
ELSE pass('migrate path (no extension): schema name check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok((SELECT coalesce(n, 0) FROM ext_members WHERE catalog = 'pg_proc') > 0,
       'the installer functions are members of pg_semantius')
ELSE pass('migrate path (no extension): function membership check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM ext_members
         WHERE catalog NOT IN ('pg_namespace', 'pg_proc')), 0,
       'pg_semantius has no members outside the schema and its functions')
ELSE pass('migrate path (no extension): member catalog check skipped') END;

-- Nothing in the five core schemas may belong to ANY extension but the
-- allow-list: such an object would be dropped with that extension and skipped
-- by pg_dump.
SELECT is(
    (SELECT coalesce(string_agg(DISTINCT e.extname, ', '), '')
       FROM pg_depend d
       JOIN pg_extension e ON e.oid = d.refobjid
       JOIN pg_class c ON c.oid = d.objid
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE d.refclassid = 'pg_extension'::regclass
        AND d.deptype = 'e'
        AND n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
        AND e.extname NOT IN ('pgcrypto', 'plpgsql_check')),
    '',
    'no relation in the core schemas belongs to an unexpected extension');

SELECT is(
    (SELECT coalesce(string_agg(DISTINCT e.extname, ', '), '')
       FROM pg_depend d
       JOIN pg_extension e ON e.oid = d.refobjid
       JOIN pg_proc p ON p.oid = d.objid
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE d.refclassid = 'pg_extension'::regclass
        AND d.deptype = 'e'
        AND n.nspname IN ('public', 'common', 'rbac', 'audit', 'pgmq')
        AND e.extname NOT IN ('pgcrypto', 'plpgsql_check')),
    '',
    'no function in the core schemas belongs to an unexpected extension');

-- -----------------------------------------------------------------------
-- GROUP 2 and 3: no dump registry, and control-file pinning
-- -----------------------------------------------------------------------

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok((SELECT extconfig IS NULL FROM pg_extension WHERE extname = 'pg_semantius'),
       'pg_semantius registers no tables for pg_dump (extconfig IS NULL)')
ELSE pass('migrate path (no extension): extconfig check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT extnamespace::regnamespace::text FROM pg_extension
         WHERE extname = 'pg_semantius'), 'public',
       'pg_semantius is pinned to schema public')
ELSE pass('migrate path (no extension): extnamespace check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok((SELECT NOT extrelocatable FROM pg_extension WHERE extname = 'pg_semantius'),
       'pg_semantius is not relocatable')
ELSE pass('migrate path (no extension): relocatable check skipped') END;

-- -----------------------------------------------------------------------
-- GROUP 4: the installer functions are locked down
-- -----------------------------------------------------------------------

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'semantius'
           AND has_function_privilege('public', p.oid, 'EXECUTE')), 0,
       'no semantius function is EXECUTE-able by PUBLIC')
ELSE pass('migrate path (no extension): function ACL check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'semantius' AND p.prosecdef), 0,
       'no semantius function is SECURITY DEFINER')
ELSE pass('migrate path (no extension): prosecdef check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'semantius'
           AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) AS c
                            WHERE c LIKE 'search\_path=%')), 0,
       'every semantius function pins search_path')
ELSE pass('migrate path (no extension): proconfig check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'semantius'
           AND obj_description(p.oid, 'pg_proc') IS NULL), 0,
       'every semantius function has a comment')
ELSE pass('migrate path (no extension): comment check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok(NOT has_schema_privilege('public', 'semantius', 'USAGE'),
       'the semantius schema is not usable by PUBLIC')
ELSE pass('migrate path (no extension): schema ACL check skipped') END;

-- -----------------------------------------------------------------------
-- GROUP 5: the ledger matches the bundle
-- -----------------------------------------------------------------------

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is(pg_temp.ext_pending(), 0,
       'pending() is empty after migrate()')
ELSE pass('migrate path (no extension): pending() check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is(pg_temp.ext_version(),
       (SELECT extversion FROM pg_extension WHERE extname = 'pg_semantius'),
       'version() equals the installed extension version')
ELSE pass('migrate path (no extension): version() check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok((SELECT count(*) FROM public._versions WHERE name LIKE '_core.%') > 0,
       '_versions records the _core migrations the installer applied')
ELSE pass('migrate path (no extension): _versions check skipped') END;

-- Every applied _core row carries a checksum, on both install paths.
SELECT is((SELECT count(*)::int FROM public._versions
            WHERE name LIKE '_core.%' AND checksum IS NULL), 0,
          'every applied _core migration recorded a checksum');

-- -----------------------------------------------------------------------
-- GROUP 6: privileges
-- -----------------------------------------------------------------------

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    throws_ok(
      'SET LOCAL ROLE authenticated; SELECT semantius.migrate()',
      '42501',
      NULL,
      'a non-superuser cannot run semantius.migrate()')
ELSE pass('migrate path (no extension): migrate() privilege check skipped') END;

RESET ROLE;

-- -----------------------------------------------------------------------
-- GROUP 7: skip_audit is gone (it was the member-table workaround)
-- -----------------------------------------------------------------------

CREATE TABLE public.audit_gate_probe (id serial PRIMARY KEY, note text);

SELECT lives_ok(
  $$SELECT set_config('pg_semantius.skip_audit', 'on', true)$$,
  'pg_semantius.skip_audit can still be set (it is simply ignored)');

-- The DDL above is audited even though skip_audit is on.
SELECT CASE WHEN (SELECT su FROM ext_ctx) THEN
    ok((SELECT count(*) FROM public.audit_ddl_logs
         WHERE object_identity LIKE '%audit_gate_probe%') > 0,
       'skip_audit = on no longer silences the DDL audit trigger')
ELSE pass('not a superuser session: skip_audit DDL check skipped') END;

-- -----------------------------------------------------------------------
-- GROUP 8: DROP EXTENSION is inert (rolled back, so it does not affect the
-- rest of the suite). Joins pg_namespace by NAME, not ::regnamespace, because
-- a dropped schema would make the cast raise instead of returning false.
-- -----------------------------------------------------------------------

CREATE TEMP TABLE drop_before AS
SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('public','common','rbac','audit','pgmq')
           AND c.relkind IN ('r','p','v','S')) AS relations,
       (SELECT count(*) FROM pg_policies)                              AS policies,
       (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal)        AS triggers,
       (SELECT count(*) FROM pg_event_trigger)                         AS evt_triggers,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname IN ('public','common','rbac','audit','pgmq')) AS functions,
       (SELECT count(*) FROM public._versions)                         AS versions;

SAVEPOINT before_drop;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    lives_ok('DROP EXTENSION pg_semantius',
             'DROP EXTENSION succeeds without CASCADE')
ELSE pass('migrate path (no extension): DROP EXTENSION check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('public','common','rbac','audit','pgmq')
           AND c.relkind IN ('r','p','v','S')),
       (SELECT relations::int FROM drop_before),
       'DROP EXTENSION keeps every core relation')
ELSE pass('migrate path (no extension): relation survival check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_policies),
       (SELECT policies::int FROM drop_before),
       'DROP EXTENSION keeps every RLS policy')
ELSE pass('migrate path (no extension): policy survival check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_trigger WHERE NOT tgisinternal),
       (SELECT triggers::int FROM drop_before),
       'DROP EXTENSION keeps every trigger')
ELSE pass('migrate path (no extension): trigger survival check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM pg_event_trigger),
       (SELECT evt_triggers::int FROM drop_before),
       'DROP EXTENSION keeps every event trigger')
ELSE pass('migrate path (no extension): event trigger survival check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    is((SELECT count(*)::int FROM public._versions),
       (SELECT versions::int FROM drop_before),
       'DROP EXTENSION keeps the _versions ledger and its rows')
ELSE pass('migrate path (no extension): _versions survival check skipped') END;

SELECT CASE WHEN (SELECT ext FROM ext_ctx) THEN
    ok(NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'semantius'),
       'DROP EXTENSION removes the semantius schema itself')
ELSE pass('migrate path (no extension): schema removal check skipped') END;

ROLLBACK TO SAVEPOINT before_drop;

SELECT * FROM finish();
ROLLBACK;
