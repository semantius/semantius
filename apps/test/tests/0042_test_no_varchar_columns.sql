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
BEGIN;

SELECT plan(2);

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

SELECT * FROM finish();

ROLLBACK;
