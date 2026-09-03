/**
 * pg_dump registration for the extension's member tables.
 *
 * Every table the install script creates becomes a member of the extension,
 * and pg_dump treats member tables as part of the extension's code: the dump
 * contains `CREATE EXTENSION pg_semantius` and none of their rows. The only
 * way to get a member table's rows into a dump is for the extension script
 * itself to call `pg_extension_config_dump(table, condition)`. Without this
 * section a plain pg_dump/pg_restore exits 0 and silently loses every user,
 * role, permission, entity, field, module, API key and queue definition
 * (release review item B1).
 *
 * This file is the single source of truth. `renderConfigDump()` turns the
 * registry into the final section of the full install and of every upgrade
 * script (re-registering a table only updates its condition, so emitting it
 * on every upgrade is safe), followed by two guards: the install fails when
 * a member table or sequence is neither registered nor listed as transient,
 * and a fresh install also fails when a registered condition still selects
 * a row the install seeds (the tables hold nothing else at that point). A
 * future migration therefore cannot add a table, or a seeded row, that is
 * silently mishandled by backups: `CREATE EXTENSION` refuses, and
 * `apps/test/tests/0440_test_config_dump.sql` pins the same rules on the
 * suite's data. `pgdocker/pg-ext-dump-restore.sh` proves the round trip on
 * the extension stack.
 *
 * Conditions
 * ----------
 * A condition selects the rows to DUMP. What it leaves out is what the
 * install script seeds itself, because `CREATE EXTENSION` re-creates those
 * rows on the restore side and a COPY of the same keys would collide. Seeded
 * rows are identified by the reserved id ranges of `0040_rbac_seed.sql`
 * (`modules.id < 1000`, `permissions.id` and `roles.id < 10000`) and by
 * well-known keys. pg_dump evaluates a condition inside
 * `COPY (SELECT ... FROM <table> <condition>) TO stdout` with
 * `search_path = pg_catalog`, so every table reference inside a condition
 * must be schema-qualified.
 *
 * Restoring (release review item B3)
 * ----------------------------------
 * The registered rows cannot be restored in a single pg_restore pass: the
 * member tables carry foreign-key cycles (`modules` <-> `permissions`/`roles`)
 * and data-dictionary DML triggers (`create_table_trigger` on `entities`,
 * `add_field_trigger` on `fields`, the permission auto-grant and the user
 * auto-role triggers) that must not fire while rows are copied. The restore
 * is three passes: `--section=pre-data`, `--data-only --disable-triggers`,
 * `--section=post-data`, run with `PGOPTIONS='-c pg_semantius.skip_audit=on'`
 * so that neither the `CREATE EXTENSION` of the first pass nor the restore's
 * own DDL writes audit rows (both audit tables are dumped in full, and rows
 * written by the restore itself would take the ids of the rows being copied
 * back; `_core/0150` honours the setting in superuser sessions). The
 * generated README (buildReadme in extension.ts) documents it for consumers.
 */

export interface ConfigDumpTable {
  /** Schema-qualified relation name. */
  rel: string;
  /** pg_dump filter starting with WHERE, or '' to dump every row. */
  condition: string;
  /** What the condition leaves out (the rows the install seeds). */
  seeded: string;
}

export interface ConfigDumpExclusion {
  rel: string;
  why: string;
}

/**
 * Tables whose rows pg_dump must include, with the filter that keeps the
 * install-seeded rows out. Order is cosmetic (the emitted SQL keeps it).
 */
export const CONFIG_DUMP_TABLES: ConfigDumpTable[] = [
  {
    rel: "public.modules",
    condition: "WHERE id >= 1000",
    seeded: "id 1 (_core)",
  },
  {
    rel: "public.permissions",
    condition: "WHERE id >= 10000",
    seeded: "ids 1-4",
  },
  {
    rel: "public.roles",
    condition: "WHERE id >= 10000",
    seeded: "ids 1-2 (User, Administrator)",
  },
  {
    rel: "public.permission_hierarchy",
    condition:
      "WHERE including_permission_id >= 10000 OR included_permission_id >= 10000",
    seeded: "(2,1)",
  },
  {
    rel: "public.role_permissions",
    condition: "WHERE role_id >= 10000 OR permission_id >= 10000",
    seeded:
      "the five seeded pairs; auto-grants of user permissions to Administrator are dumped",
  },
  {
    rel: "public.entities",
    condition: "WHERE module_id >= 1000",
    seeded: "the core entities (module 1)",
  },
  {
    rel: "public.fields",
    condition:
      "WHERE table_name IN (SELECT table_name FROM public.entities WHERE module_id >= 1000)",
    seeded:
      "fields of the core entities, including any added to them later (README caveat)",
  },
  {
    rel: "public._settings",
    condition: "WHERE name <> 'db_version'",
    seeded: "db_version (maintained by the notify triggers)",
  },
  {
    rel: "public._versions",
    condition: "WHERE split_part(name, '.', 1) <> '_core'",
    seeded:
      "the _core.* run-once guards (re-seeded by the install); other apps' guards are kept so `migrate` does not re-run them after a restore",
  },
  {
    rel: "pgmq.meta",
    condition: "WHERE queue_name <> 'raci_notify'",
    seeded:
      "raci_notify (created by 0210_raci.sql); user queues' q_*/a_* tables are not members and dump normally",
  },
  {
    rel: "public.queues",
    condition: "WHERE queue_name <> 'raci_notify'",
    seeded: "the raci_notify queue definition (0210_raci.sql)",
  },
  {
    rel: "public.queue_table_events",
    condition:
      "WHERE NOT (table_name = 'raci_events' AND queue_id IN (SELECT id FROM public.queues WHERE queue_name = 'raci_notify'))",
    seeded: "the raci_events -> raci_notify wiring (0210_raci.sql)",
  },
  // User data only; the install seeds nothing in these (the full install
  // proves it: its guard counts what every condition would dump right after
  // the seed and refuses to install when that is not zero).
  ...[
    "public.users",
    "public.user_roles",
    "public.user_permissions",
    "public._apikeys",
    "public.dashboards",
    "public.user_bookmarks",
    "public.webhook_receivers",
    "public.webhook_receiver_logs",
    "public.processes",
    "public.process_gates",
    "public.raci_assignments",
    "public.raci_events",
    "public.audit_record_logs",
    "public.audit_ddl_logs",
    "pgmq.topic_bindings",
  ].map((rel) => ({ rel, condition: "", seeded: "nothing" })),
];

/**
 * Sequences whose current value must survive a restore. Without them a
 * restored database restarts `modules_id_seq` at 1000 and the next module
 * collides with a restored one.
 */
export const CONFIG_DUMP_SEQUENCES: string[] = [
  "public.modules_id_seq",
  "public.permissions_id_seq",
  "public.roles_id_seq",
  "public.users_id_seq",
  "public._apikeys_id_seq",
  "public.dashboards_id_seq",
  "public.user_bookmarks_id_seq",
  "public.webhook_receivers_id_seq",
  "public.webhook_receiver_logs_id_seq",
  "public.processes_id_seq",
  "public.process_gates_id_seq",
  "public.queues_id_seq",
  "public.queue_table_events_id_seq",
  "public.raci_assignments_id_seq",
  "public.raci_events_id_seq",
  "public.audit_record_logs_id_seq",
  "public.audit_ddl_logs_id_seq",
];

/**
 * Member relations deliberately left out of the dump. Every member table or
 * sequence must appear either above or here; the emitted guard and test 0440
 * enforce it.
 */
export const CONFIG_DUMP_EXCLUDED: ConfigDumpExclusion[] = [
  { rel: "common._cache", why: "unlogged per-request cache" },
  { rel: "common._cache_id_seq", why: "belongs to common._cache" },
  {
    rel: "pgmq.notify_insert_throttle",
    why: "unlogged notification throttle state",
  },
  {
    rel: "pgmq.q_raci_notify",
    why: "in-flight RACI notifications; the queue is re-created by the install",
  },
  { rel: "pgmq.q_raci_notify_msg_id_seq", why: "belongs to pgmq.q_raci_notify" },
  { rel: "pgmq.a_raci_notify", why: "archive of the transient RACI queue" },
];

/** SQL string literal. */
function lit(text: string): string {
  return `'${text.replace(/'/g, "''")}'`;
}

/**
 * Renders the pg_dump registration section: one `pg_extension_config_dump`
 * call per registered table and sequence, then two guards. The completeness
 * guard (every member table and sequence is registered or transient) runs in
 * every script. The seed guard runs in the full install only: right after the
 * install the tables hold nothing but the seeded rows, so every condition must
 * select zero rows there; an upgrade script cannot use it because the tables
 * hold user data by then. Emitted as the last section of the full install and
 * of every upgrade script, because both run with `creating_extension` set
 * (the only context in which `pg_extension_config_dump` may be called).
 */
export function renderConfigDump(
  name: string,
  opts: { freshInstall: boolean },
): string {
  const rows = [
    ...CONFIG_DUMP_TABLES.map((t) =>
      `            (${lit(t.rel)}, ${lit(t.condition)})`
    ),
    ...CONFIG_DUMP_SEQUENCES.map((s) => `            (${lit(s)}, '')`),
  ].join(",\n");
  const excluded = CONFIG_DUMP_EXCLUDED.map((e) => lit(e.rel)).join(", ");
  const excludedNotes = CONFIG_DUMP_EXCLUDED.map((e) =>
    `--   ${e.rel}: ${e.why}`
  ).join("\n");
  const seedGuard = opts.freshInstall
    ? `
    -- Guard (fresh install only): the tables hold nothing but the seeded
    -- rows at this point, so every registered condition must select zero
    -- rows. A seeded row that a condition still selects would be dumped
    -- and collide with the re-seeded row on restore.
    FOR v_rel IN
        SELECT n.nspname AS nsp, c.relname AS rel, cfg.condition
          FROM pg_catalog.pg_extension e
          CROSS JOIN LATERAL unnest(e.extconfig, e.extcondition) AS cfg(relid, condition)
          JOIN pg_catalog.pg_class c ON c.oid = cfg.relid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE e.extname = ${lit(name)} AND c.relkind IN ('r', 'p')
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I %s', v_rel.nsp, v_rel.rel, v_rel.condition)
           INTO v_count;
        IF v_count > 0 THEN
            v_leaking := array_append(v_leaking, v_rel.nsp || '.' || v_rel.rel || ' (' || v_count || ')');
        END IF;
    END LOOP;
    IF v_leaking IS NOT NULL THEN
        RAISE EXCEPTION '${name}: seeded rows that pg_dump would dump: %', array_to_string(v_leaking, ', ')
            USING HINT = 'Narrow the condition in CONFIG_DUMP_TABLES (packages/cli/commands/extension-dump.ts) so the rows the install seeds are left out, and regenerate the extension.';
    END IF;
`
    : "";

  return `-- =====================================================
-- pg_dump registration (pg_extension_config_dump)
-- =====================================================
-- Member tables of an extension are not dumped by pg_dump unless
-- the extension registers them here. Each condition selects the
-- rows to dump and leaves out what the install script seeds
-- itself (CREATE EXTENSION re-creates those on the restore
-- side). pg_dump evaluates the conditions with
-- search_path = pg_catalog, so references are schema-qualified.
-- A single-pass pg_restore fails on the FK cycles and the
-- data-dictionary triggers; restore in three passes, see
-- README.md "Backup and restore".
-- Source of truth: packages/cli/commands/extension-dump.ts.
-- Left out on purpose:
${excludedNotes}
DO $config_dump$
DECLARE
    v_rel record;
    v_unregistered text;
    v_count bigint;
    v_leaking text[];
BEGIN
    FOR v_rel IN
        SELECT * FROM (VALUES
${rows}
        ) AS t(rel, condition)
    LOOP
        PERFORM pg_catalog.pg_extension_config_dump(v_rel.rel::regclass, v_rel.condition);
    END LOOP;

    -- Guard: every member table and sequence is either registered
    -- above or a documented transient. A new dictionary table that is
    -- neither fails the install here (and test 0440), so it cannot
    -- ship silently missing from backups.
    SELECT string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY n.nspname, c.relname)
      INTO v_unregistered
      FROM pg_catalog.pg_depend d
      JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
      JOIN pg_catalog.pg_class c ON c.oid = d.objid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE d.classid = 'pg_catalog.pg_class'::regclass
       AND d.refclassid = 'pg_catalog.pg_extension'::regclass
       AND d.deptype = 'e'
       AND e.extname = ${lit(name)}
       AND c.relkind IN ('r', 'p', 'S')
       AND NOT (c.oid = ANY (COALESCE(e.extconfig, '{}')))
       AND n.nspname || '.' || c.relname NOT IN (${excluded});
    IF v_unregistered IS NOT NULL THEN
        RAISE EXCEPTION '${name}: member relations not registered with pg_extension_config_dump: %', v_unregistered
            USING HINT = 'Add them to CONFIG_DUMP_TABLES, CONFIG_DUMP_SEQUENCES or CONFIG_DUMP_EXCLUDED in packages/cli/commands/extension-dump.ts and regenerate the extension.';
    END IF;
${seedGuard}END
$config_dump$;

`;
}
