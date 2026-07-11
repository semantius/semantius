-- Test that no user-defined functions exist without a pinned search_path
-- Functions without search_path in proconfig are potentially vulnerable to
-- search_path hijacking attacks.
--
-- Also test that every user-defined function carries a COMMENT (documentation
-- invariant). Third-party extension functions (pgmq, pgcrypto, …) are excluded:
-- they are extension-owned (pg_depend deptype='e') or live in an excluded schema.
BEGIN;

SELECT plan(2);

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
            'pgrst', 'pgtap', 'pgtle', 'realtime', 'repack', 'storage',
            'supabase_functions', 'supabase_migrations', 'tiger', 'topology', 'vault'
        )
        AND dep.objid IS NULL
        AND NOT EXISTS (
            SELECT 1
            FROM unnest(coalesce(p.proconfig, '{}')) AS config
            WHERE config LIKE 'search_path=%'
        )$$,
    'All user-defined functions should have a pinned search_path'
);

-- Every user-defined function (including per-table generated _label / <fk>_label,
-- compute_validate_* and select_rule_* functions) must have a COMMENT.
SELECT is_empty(
    $$SELECT
        jsonb_build_object(
            'schema', n.nspname,
            'name', p.proname,
            'args', pg_catalog.pg_get_function_identity_arguments(p.oid)
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
            'pgrst', 'pgtap', 'pgtle', 'realtime', 'repack', 'storage',
            'supabase_functions', 'supabase_migrations', 'tiger', 'topology', 'vault'
        )
        AND dep.objid IS NULL
        AND pg_catalog.obj_description(p.oid, 'pg_proc') IS NULL$$,
    'All user-defined functions should have a COMMENT'
);

SELECT * FROM finish();
ROLLBACK;
