-- Catalog hygiene guards, checked against the live catalog after every
-- migration has run.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. No unmanaged out-of-the-box entities
--   2. No VARCHAR columns
--   3. _core comments match the data dictionary
BEGIN;

SELECT plan(10);

-- =====================================================
-- PART 1: No unmanaged out-of-the-box entities
-- =====================================================
-- Guard: out-of-the-box entities must not be registered managed=FALSE.
--
-- managed=FALSE silently disables the DD machinery (create_table_trigger /
-- add_field_trigger) for a table, so foreign keys, columns, RLS policies and
-- enum CHECKs declared via field metadata are NOT created. That is exactly how
-- process_gates.entity ended up with a `reference` field but no backing FK,
-- which broke PostgREST embedding (PGRST200).
--
-- The ONLY sanctioned exceptions are the two audit log tables: they are
-- trigger-populated system logs (int64 ids, computed uuid columns) that
-- intentionally sit outside the managed DD model. If a new table legitimately
-- needs to be unmanaged, add it to the allowlist below together with a reason.

SELECT authenticate_as('user3');

-- 1. No entity outside the allowlist may be unmanaged. On failure pgTAP prints
--    the offending table names, so a future reoccurence is named.
SELECT is(
    (SELECT COALESCE(array_agg(table_name ORDER BY table_name), ARRAY[]::text[])
       FROM entities
      WHERE managed = FALSE
        AND table_name NOT IN ('audit_record_logs', 'audit_ddl_logs')),
    ARRAY[]::text[],
    'No OOTB entity may be registered managed=FALSE (audit_record_logs / audit_ddl_logs are the only sanctioned exceptions)'
);

-- 2. The allowlisted audit tables are still present and still unmanaged. Keeps
--    the allowlist honest: if these are ever changed, revisit this test.
SELECT is(
    (SELECT count(*)::int
       FROM entities
      WHERE managed = FALSE
        AND table_name IN ('audit_record_logs', 'audit_ddl_logs')),
    2,
    'Both audit tables remain registered as the sanctioned unmanaged exceptions'
);

-- 3. The allowlist is enforced, not only asserted. enable_dd_table configures an
--    adopted table as a managed one - the four permission policies and a grant
--    of INSERT and UPDATE - and on these two that is not adoption but unlocking:
--    the log would become writable by whoever holds its edit_permission. The
--    flip itself is refused, which is what lets adoption stay unconditional for
--    every other table.

SELECT throws_ok(
    $$UPDATE entities SET managed = TRUE WHERE table_name = 'audit_record_logs'$$,
    '90602',
    NULL,
    'audit_record_logs cannot be made managed'
);

SELECT throws_ok(
    $$UPDATE entities SET managed = TRUE WHERE table_name = 'audit_ddl_logs'$$,
    '90602',
    NULL,
    'audit_ddl_logs cannot be made managed'
);

-- 4. An ordinary entity edit on those rows is untouched: the trigger is scoped
--    to the managed column and only refuses FALSE -> TRUE.
SELECT lives_ok(
    $$UPDATE entities SET description = 'DML audit trail' WHERE table_name = 'audit_record_logs'$$,
    'an ordinary edit of an audit entity is not affected by the guard'
);

SELECT lives_ok(
    $$UPDATE entities SET managed = FALSE WHERE table_name = 'audit_record_logs'$$,
    'writing managed = FALSE over FALSE is not a flip and is allowed'
);

-- =====================================================
-- PART 2: No VARCHAR columns
-- =====================================================
-- Guard: no VARCHAR / character varying column in a Semantius-owned schema.
--
-- TEXT and VARCHAR without a length limit are the same type in PostgreSQL, so a
-- stray VARCHAR costs nothing at runtime - but it does leak: format_type() puts
-- "character varying" into every catalog readout, the reference-type resolver in
-- add_dd_field copies the referenced key's catalog type verbatim into the column
-- it creates, and the data dictionary has no `varchar` format to describe it
-- with. One spelling for string columns keeps all three honest. A column that
-- genuinely needs a length limit is a business rule and needs an entry here
-- together with its reason.
--
-- pgmq is excluded, and this test must never be "fixed" by editing it: it is
-- vendored upstream code, kept byte-identical to the release it came from, and
-- whatever it declares is not ours to change. The sweep below names the four
-- schemas Semantius owns rather than excluding pgmq, so a new vendored schema
-- is out of scope by default instead of by remembering to list it.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is_empty(
    $$SELECT
        jsonb_build_object(
            'schema', n.nspname,
            'table', c.relname,
            'column', a.attname,
            'type', format_type(a.atttypid, a.atttypmod)
        ) AS metadata
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('public', 'common', 'rbac', 'audit')
      AND c.relkind IN ('r', 'p', 'v', 'm')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.atttypid = 'pg_catalog.varchar'::regtype$$,
    'No VARCHAR column in public, common, rbac or audit'
);

-- The five generated key columns are the ones this guard was written for: they
-- were VARCHAR until the type was normalized, and they are the only string
-- primary keys the DDL declares by hand rather than through the dictionary.
SELECT is(
    (SELECT COALESCE(array_agg(c.relname || '.' || a.attname ORDER BY c.relname), ARRAY[]::text[])
       FROM pg_catalog.pg_attribute a
       JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname IN ('user_roles', 'role_permissions', 'user_permissions',
                          'permission_hierarchy', 'fields')
        AND a.attname = 'id'
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND format_type(a.atttypid, a.atttypmod) = 'text'),
    ARRAY['fields.id', 'permission_hierarchy.id', 'role_permissions.id',
          'user_permissions.id', 'user_roles.id'],
    'The five generated key columns are TEXT'
);

-- =====================================================
-- PART 3: _core comments match the data dictionary
-- =====================================================
-- The table and column comments of the _core tables are generated from the DD
-- (dd_table_comment / dd_field_comment), in 0240_dd_bootstrap_complete.once.sql
-- for the tables seeded before the
-- triggers exist and by the triggers for the rest. PostgREST shows these comments
-- as descriptions in its OpenAPI output, so the DD description has to stay their
-- only source. A COMMENT ON statement in a migration overwrites the generated text
-- and drifts from the DD the moment either side changes; both checks list every
-- table or column that no longer matches.
--
-- The two audit tables keep their longer table comments on purpose (what the
-- event triggers capture and why), so they are left out of the table check. Their
-- column comments come from the DD like every other and are checked.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is_empty(
    $$SELECT f.id
      FROM fields f
      JOIN entities e ON e.table_name = f.table_name
      JOIN modules m ON m.id = e.module_id AND m.module_name = '_core'
      JOIN pg_attribute a
        ON a.attrelid = format('public.%I', f.table_name)::regclass
       AND a.attname = f.field_name AND NOT a.attisdropped
      WHERE col_description(a.attrelid, a.attnum)
            IS DISTINCT FROM dd_field_comment(f.title, f.format, f.description, f.enum_values)$$,
    'every _core column comment equals the comment generated from its DD field'
);

SELECT is_empty(
    $$SELECT e.table_name
      FROM entities e
      JOIN modules m ON m.id = e.module_id AND m.module_name = '_core'
      WHERE e.table_name NOT IN ('audit_record_logs', 'audit_ddl_logs')
        AND obj_description(format('public.%I', e.table_name)::regclass, 'pg_class')
            IS DISTINCT FROM dd_table_comment(e.plural_label, e.description)$$,
    'every _core table comment except the audit tables equals the comment generated from its entity'
);

SELECT * FROM finish();
ROLLBACK;
