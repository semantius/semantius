-- Test that no user-defined functions exist without a pinned search_path
-- Functions without search_path in proconfig are potentially vulnerable to
-- search_path hijacking attacks.
BEGIN;

SELECT plan(1);

SELECT is_empty(
    $$SELECT
        jsonb_build_object(
            'schema', n.nspname,
            'name', p.proname,
            'type', 'function'
        ) AS metadata
    FROM
        pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n
            ON p.pronamespace = n.oid
        LEFT JOIN pg_catalog.pg_depend dep
            ON p.oid = dep.objid
            AND dep.deptype = 'e'
    WHERE
        n.nspname NOT IN (
            '_timescaledb_cache', '_timescaledb_catalog', '_timescaledb_config',
            '_timescaledb_internal', 'auth', 'cron', 'extensions', 'graphql',
            'graphql_public', 'information_schema', 'net', 'pgmq', 'pgroonga',
            'pgsodium', 'pgsodium_masks', 'pgtle', 'pgbouncer', 'pg_catalog',
            'pgtap', 'pgtle', 'realtime', 'repack', 'storage', 'supabase_functions',
            'supabase_migrations', 'tiger', 'topology', 'vault'
        )
        AND dep.objid IS NULL
        AND NOT EXISTS (
            SELECT 1
            FROM unnest(coalesce(p.proconfig, '{}')) AS config
            WHERE config LIKE 'search_path=%'
        )$$,
    'All user-defined functions should have a pinned search_path'
);

SELECT * FROM finish();
ROLLBACK;
