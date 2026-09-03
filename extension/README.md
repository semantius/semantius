# pg_semantius 0.5.0

Semantius core for PostgreSQL: role-based access control, row-level security,
a semantic data dictionary, and a message queue.

## Install

Two statements, as a superuser, in a UTF8 database:

```sql
CREATE EXTENSION pg_semantius;
SELECT semantius.migrate();
```

Do **not** use `CASCADE`. `CREATE EXTENSION` creates only the cluster roles,
the `semantius` schema and its functions. `semantius.migrate()` then installs the
core schema - tables, functions, triggers, policies and seed rows - as
**ordinary objects**. They are deliberately *not* extension members, which is
what makes a plain backup, a single-pass restore and a harmless
`DROP EXTENSION` possible.

`pgcrypto` is a runtime prerequisite. `semantius.migrate()` creates it in
`public`, where the API-key code needs it; if it is already installed in
another schema the install refuses with a hint.

## Upgrade

```sql
ALTER EXTENSION pg_semantius UPDATE;
SELECT semantius.migrate();
```

`ALTER EXTENSION ... UPDATE` replaces the installer functions; `migrate()`
applies whatever is new. Both are safe to re-run: `migrate()` is idempotent
per migration. `SELECT * FROM semantius.pending()` lists what a `migrate()`
would apply; `SELECT * FROM semantius.status()` reports drift.

## Functions

| Function | Purpose |
|---|---|
| `semantius.migrate()` | Applies the bundled migrations. Superuser only, idempotent, one transaction. |
| `semantius.pending()` | Bundled migrations not yet applied. Works before the first migrate(). |
| `semantius.version()` | Version of the installed bundle. |
| `semantius.status()` | Applied/pending counts, unknown or changed migrations, ownership and default-ACL drift. |

`\dx` shows the *installer's* version, which is not necessarily the state of
the installed schema; `semantius.status()` is the authority.

## Backup and restore

Backup is a plain dump and restore is a single pass. No flags, no environment
variables, no ordering rules:

```sh
pg_dump -Fc -d appdb -f appdb.dump          # as a superuser or a BYPASSRLS role
createdb -T template0 newdb
pg_restore -d newdb appdb.dump              # one pass, same cluster or a fresh one
```

`-Fp` piped to psql, `-j` and `-1` all work too. Facts worth knowing:

- Restore into an **empty** database. Do not run `migrate()` first: the dump's
  own `CREATE EXTENSION` recreates the roles and functions.
- Restore as a superuser **named like the installing one** (`postgres` in the
  shipped images) and **not** with `--no-owner`. A differently named superuser
  still gets working data, but the schemas and event triggers stay owned by the
  restorer and the installer's default-privilege entries are lost, so functions
  created by hand later would be PUBLIC-executable. `semantius.status()` reports
  this.
- On a **fresh cluster** the four roles are recreated by the dump's
  `CREATE EXTENSION`, but they are NOLOGIN and without passwords: rerun your
  deployment's login step.
- If the extension files are **absent** on the target server, the dump's
  `CREATE EXTENSION` and `COMMENT ON EXTENSION` fail and everything else
  restores, so the database still works. On a fresh cluster the four roles are
  then missing too: create them first (`pg_dumpall --globals-only`).
- A dump taken **after** `DROP EXTENSION` carries no `CREATE EXTENSION`, so
  the same rule applies.
- UTF8 databases only. LATIN1 and SQL_ASCII are refused at install time.

## Uninstall

`DROP EXTENSION pg_semantius` removes the `semantius` schema and its functions and
**nothing else** - never CASCADE, never any data. To remove Semantius
completely, in this order (step 3 **deletes all data**):

```sql
DROP EXTENSION pg_semantius;
DROP EVENT TRIGGER track_ddl_changes, pgrst_ddl_watch, pgrst_drop_watch;
DROP OWNED BY semantius_owner CASCADE;      -- deletes all Semantius data
DROP SCHEMA IF EXISTS common, rbac, audit, pgmq CASCADE;
DROP TABLE IF EXISTS public._versions;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM semantius_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE USAGE, SELECT ON SEQUENCES FROM semantius_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
DROP OWNED BY semantius_user, authenticated, semantius_authenticator;
-- only if no other database in this cluster uses them:
DROP ROLE semantius_user, authenticated, semantius_authenticator, semantius_owner;
```

The event triggers go first because they fire on every drop below them.

The last statement leaves one `pg_default_acl` row behind
(`public | FUNCTIONS | {=X/postgres}`). That is the built-in default written
out explicitly rather than a leftover privilege: a function created afterwards
gets the default ACL and PUBLIC can execute it, exactly as in a database that
never had pg_semantius installed.

## Roles

Created by `CREATE EXTENSION` (cluster-wide, never dropped with it). All four
are NOLOGIN and passwordless; grant LOGIN and a password per environment.

| Role | Purpose |
|---|---|
| `semantius_owner` | Owns the core objects; the identity the SECURITY DEFINER dictionary code runs as. NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS. |
| `semantius_user` | The request role. Subject to RLS. |
| `authenticated` | Holds `semantius_user`; what an authenticated session acts as. |
| `semantius_authenticator` | Session-mode login role; NOINHERIT, can only `SET ROLE authenticated`. |

An existing role is verified rather than adopted: if one of these already
exists with unexpected attributes, or `semantius_owner` already has members,
the install refuses.

## Session settings the caller controls

`migrate()` pins `search_path`, `standard_conforming_strings` and
`check_function_bodies`, and forces `session_replication_role = origin`, so
an unusual session cannot change what gets installed. It still fails, by
design, under `default_transaction_read_only`, a `statement_timeout` or
`lock_timeout` shorter than the install, or an isolation level above read
committed.

## Runtime configuration

The code reads these settings from the session:

| Setting | Set by |
|---|---|
| `request.jwt.claims` | PostgREST or your app tier, per request |
| `request.jwt.claim.sub`, `request.jwt.claim.email`, `request.jwt.claim.role`, `request.jwt.claim.name`, `request.jwt.claim.given_name`, `request.jwt.claim.family_name`, `request.jwt.claim.aud` | the same, one GUC per claim (Neon/Supabase style) |
| `app.current_user_id`, `app.user_permissions`, `app.oauth_scopes`, `app.current_external_id`, `app.context_initialized`, `app.bumping_module_version`, `app.bearer_cache_notice` | the RBAC code itself, per transaction |
| `dd.table_rename` | the data dictionary, during a table rename |

DDL emits `NOTIFY pgrst, 'reload schema'` so PostgREST reloads its cache, and
the audit event trigger records DDL in `public.audit_ddl_logs`.

## Errors

| SQLSTATE | Message |
|---|---|
| - | `permission denied to create extension "pg_semantius"` / `Must be superuser to create this extension` |
| - | `extension "pg_semantius" must be installed in schema "public"` |
| 42501 | `permission denied for schema semantius` |
| 42501 | `semantius.migrate() must be run by a superuser (current_user is ...)` |
| 55000 | `pg_semantius requires a UTF8 database` |
| 55000 | `the pgmq extension is installed; pg_semantius vendors its own pgmq schema` |
| 55000 | `pgcrypto must be installed in schema public` |
| 55000 | `existing role semantius_owner has unexpected attributes` |
| 55000 | `semantius.migrate() cannot run inside a CREATE/ALTER EXTENSION script` |

## Requirements

PostgreSQL 18 (the only tested version), a UTF8 database, and superuser rights
to install. Security model and reporting: see `SECURITY.md` in this archive.
