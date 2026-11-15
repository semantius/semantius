-- Test that no user-defined functions exist without a pinned search_path
-- Functions without search_path in proconfig are potentially vulnerable to
-- search_path hijacking attacks.
--
-- Also test that every user-defined function carries a COMMENT (documentation
-- invariant). Third-party extension functions (pgmq, pgcrypto, …) are excluded:
-- they are extension-owned (pg_depend deptype='e') or live in an excluded schema.
-- pgmq is excluded on purpose, from both lists. Its functions are vendored upstream code kept
-- byte-identical to the release they came from, so anything set on them from outside is undone
-- by the next vendor bump; they are not reachable from PostgREST, which exposes `public` only;
-- and what a DB-only caller gets from them is queue names, metrics and topic bindings, never
-- queue contents, which the request role cannot read. Revisit if pgmq is ever exposed or the
-- request role gains SELECT on a queue table.
BEGIN;

SELECT plan(4);

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

-- No function body may contain a carriage return. A body is stored verbatim in
-- pg_proc.prosrc, and the .sql files are CRLF in a Windows checkout and LF
-- everywhere else (core.autocrlf, and no .gitattributes pins them), so a loader
-- that passes the file through unchanged installs a textually different database
-- depending on who ran it. That is not cosmetic: a character class or a quoted
-- literal written across a line break then means one thing on one checkout and
-- another on the next, and no single machine can see the difference, because
-- each one only ever builds one of the two. Every path that feeds SQL to
-- PostgreSQL - `deno task migrate`, the generated extension script, and the
-- migrations bundles - normalizes to LF first, and this is what says so.
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
        AND p.prosrc LIKE E'%\r%'$$,
    'No function body should contain a carriage return (all install paths normalize to LF)'
);

-- No function may build another function's body inside a dollar tag it wrote
-- down itself. A generator hands its CREATE FUNCTION to EXECUTE as the owner,
-- and text an administrator wrote (a default value, a rule, a message, a
-- label) reaches the generated body through %L or quote_literal. Those protect
-- the single-quote context only: a dollar-quoted body ends at the first
-- occurrence of its tag wherever that is, a quoted literal included, so
-- metadata that contains the tag ends the body early and the rest of the text
-- runs as SQL of the owner. The tag therefore has to be one the body cannot
-- contain, which is what dd_dollar_quote (0160_dd_functions.sql)
-- derives from the body itself.
--
-- pg_proc.prosrc holds a function's body without its own delimiters, so
-- `AS $tag$` in it can only be the opening of a body the function writes for
-- another one. The empty tag counts: `$$` is as fixed as a named one. A
-- generator that passes its body through dd_dollar_quote reads `AS %s` and
-- does not match, and neither does a named tag that only quotes a format
-- template (`format($FUNC$ ... AS %s $FUNC$, ...)`): that tag is closed before
-- any metadata is spliced in. Case-insensitive, because SQL keywords are.
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
        AND p.prosrc ~* '\mAS\s+\$[A-Za-z_0-9]*\$'
    ORDER BY n.nspname, p.proname$$,
    'No function should wrap a generated function body in a fixed dollar tag'
);

SELECT * FROM finish();
ROLLBACK;
