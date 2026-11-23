# pg_semantius 0.5.0-beta1

Semantius core for PostgreSQL: role-based access control, row-level security,
a semantic data dictionary, and a message queue.

Documentation: [pg_semantius](https://www.semantius.com/docs/pg-semantius) and
the [data catalog](https://www.semantius.com/docs/data-catalog) it installs.
Source: [semantius/semantius](https://github.com/semantius/semantius).

## Install

Two statements, as a superuser with the `BYPASSRLS` attribute, in a UTF8 database:

```sql
CREATE EXTENSION pg_semantius;
CALL semantius.migrate();
```

`semantius.migrate()` is a procedure that commits after every migration file, so
run it as its own statement, not inside `BEGIN` / `COMMIT` or `psql -1`
(PostgreSQL refuses that with SQLSTATE 2D000 before anything is written). If a
file fails, the files before it stay applied, the error names the file, and the
next `CALL` continues from there.

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

Install the newer version's files on the server, then run in each database:

```sql
ALTER EXTENSION pg_semantius UPDATE;
CALL semantius.migrate();
```

`ALTER EXTENSION ... UPDATE` replaces the installer and nothing else;
`migrate()` applies whatever is due. Both are safe to re-run.
`semantius.pending()` and `semantius.status()` are part of the installer, so they
answer for the version the database's installer is at: between the two
statements, `SELECT * FROM semantius.pending()` lists what the new version's
`migrate()` would apply.

What is due is decided per file from `public._versions`, which records each
file's name and its value, `<ts>.<sha256>`: the UTC time of the release that
last changed the file, and the SHA-256 of its text.

- a file with no row runs;
- a repeatable file (`NNNN_name.sql`, `NNNN_name.jsonc`: functions,
  triggers, views, policies, entity definitions) runs again when its value
  changed;
- a run-once file (`NNNN_name.once.sql`: tables, columns, seed rows) never
  runs again;
- the files numbered 9900 and above (ownership hardening) run after any pass
  that ran something.

So a build that changed a function reaches an existing install on the next
`migrate()`. A change made by hand to an object a repeatable file creates
stays until that file changes again; to re-apply that file anyway, clear its
checksum: `UPDATE public._versions SET checksum = NULL WHERE name = '...';`.

### Databases migrate() refuses

Before the first file, `migrate()` refuses two kinds of database, with
SQLSTATE 55000. A refusal changes nothing and releases the migration lock.

- **A newer build migrated it**: a row's ts is later than this build's ts for
  that file, or a row for a file this build does not have carries a ts later
  than this build's newest. The message names the file, the row's ts and this
  build's newest ts, and ends with *use a newer pg_semantius, then ALTER
  EXTENSION pg_semantius UPDATE and CALL semantius.migrate()*.
  An older installer meets this after a restore onto a server whose extension
  files are older than the dump's.
- **It cannot be brought to this build's schema**: it recorded a run-once file
  with a value other than this build's, or it recorded a file this build does
  not have with a ts no later than this build's newest. A run-once file never
  runs again, so such a database would never get the schema this build's
  files create. The message ends with *this database cannot be updated;
  replace the database with a fresh install*: install this version into a new
  database and move the data across.

A row whose checksum is NULL is never refused. `semantius.pending()` does not
run these checks, so on a refused database it still lists the files that are
due, and `semantius.status()` lists the refused run-once files in
`changed_versions`.

### A re-release of the same version

A re-release keeps the version number, and there is no update path from a
version to itself, so `ALTER EXTENSION ... UPDATE` leaves the installer as
it was. Install the re-released files on the server, then:

```sql
DROP EXTENSION pg_semantius;
CREATE EXTENSION pg_semantius;
CALL semantius.migrate();
```

`DROP EXTENSION` removes only the installer (see Uninstall), so the data
stays, and `migrate()` then applies what the re-release changed, or refuses
the database as above.

## Functions

| Function | Purpose |
|---|---|
| `CALL semantius.migrate()` | Applies the bundled migrations that are due. Superuser only, one transaction per file, fails at once while another migration runs. |
| `semantius.pending()` | Bundled migrations that are due by the run rules above. Works before the first migrate(), and does not run migrate()'s refusal checks. |
| `semantius.version()` | Version of the installed bundle (the installer, not the installed schema). |
| `semantius.status()` | Applied/pending counts, unknown migrations (ledger rows this bundle does not have, among them those of apps the CLI deployed), run-once migrations recorded with a value other than this bundle's, ownership and default-ACL drift, and whether `jwt_aud` is set. |

`\dx` shows the *installer's* version, which is not necessarily the state of
the installed schema; `semantius.status()` is the authority.

## Backup and restore

Backup is a plain dump and restore is a single pass. No flags, no environment
variables, no ordering rules:

```sh
pg_dump -Fc -d appdb -f appdb.dump          # as a superuser or a BYPASSRLS role
createdb -T template0 -E UTF8 newdb
pg_restore -d newdb appdb.dump              # one pass, same cluster or a fresh one
psql -d newdb -c "ALTER DATABASE newdb SET timezone = 'UTC';"
psql -d newdb -c "ALTER DATABASE newdb SET intervalstyle = 'iso_8601';"
```

`-Fp` piped to psql, `-j` and `-1` all work too. Facts worth knowing:

- Restore into an **empty** database. Do not run `migrate()` first: the dump's
  own `CREATE EXTENSION` recreates the roles and functions.
- Restore onto a server whose extension files are the dump's version or
  **newer**. The dump's `CREATE EXTENSION` names no version, so it installs
  the server's default version, and an older installer's `migrate()` refuses
  the restored database as one a newer build migrated.
- The two `ALTER DATABASE` statements give the new database the
  `timezone` and `intervalstyle` that `migrate()` set. `pg_dump` and
  `pg_restore` carry them only with `--create`, and `get_userinfo()`
  refuses a session without them (90011).
- Restore as a superuser **named like the installing one** (`postgres` in the
  shipped images) and **not** with `--no-owner`. A differently named superuser
  still gets working data. On a cluster that has no role of the installer's
  name, the schemas and event triggers stay owned by the restorer and the
  installer's default-privilege entries are lost. Semantius's own `rbac`
  functions do not depend on them: each one the request role may run is
  granted to it with its definition. A function created in `rbac` by hand
  gets EXECUTE for the request role from the default-privilege entries of
  `rbac` only when the role they name, the installing role or
  `semantius_owner`, creates it; one that another role creates, the restorer
  included, is PUBLIC-executable, and so executable by the request role, until
  it is revoked from PUBLIC, and then only its owner and superusers can run it.
  `semantius.status()` reports `default_acls_ok`, which tests only that the role
  calling it has a default-privilege entry, in any schema.
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
DROP EVENT TRIGGER track_ddl_changes, track_ddl_drops, pgrst_ddl_watch, pgrst_drop_watch;
DROP OWNED BY semantius_owner CASCADE;      -- deletes all Semantius data
DROP SCHEMA IF EXISTS common, rbac, audit, pgmq CASCADE;
DROP TABLE IF EXISTS public._versions;
DROP OWNED BY semantius_user, authenticated, semantius_authenticator;
-- only if no other database in this cluster uses them:
DROP ROLE semantius_user, authenticated, semantius_authenticator, semantius_owner;
```

The event triggers go first because they fire on every drop below them. The
recipe leaves `pgcrypto` installed and keeps the `timezone` and
`intervalstyle` settings `migrate()` gave the database.

## Roles

Created by `CREATE EXTENSION` (cluster-wide, never dropped with it). All four
are NOLOGIN and passwordless; grant LOGIN and a password per environment to the
roles your deployment logs in as, never to `semantius_owner`, which
`CREATE EXTENSION` and `ALTER EXTENSION ... UPDATE` refuse once it can log in.

| Role | Purpose |
|---|---|
| `semantius_owner` | Owns the core objects; the identity the SECURITY DEFINER dictionary code runs as. NOLOGIN NOSUPERUSER NOINHERIT BYPASSRLS. |
| `semantius_user` | The request role. Subject to RLS. No default access to tables in `public`; the dictionary grants each table it creates or adopts. |
| `authenticated` | Holds `semantius_user`; what an authenticated session acts as. |
| `semantius_authenticator` | Session-mode login role; NOINHERIT, can only `SET ROLE authenticated`. |

An existing role is verified rather than adopted: if one of these already
exists with unexpected attributes, or `semantius_owner` already has members,
the install refuses.

## Session settings the caller controls

`migrate()` pins `search_path`, `standard_conforming_strings` and
`check_function_bodies`, and forces `session_replication_role = origin`,
before every file, so an unusual session cannot change what gets installed. It
still fails, by design, under `default_transaction_read_only`, a
`statement_timeout` shorter than the install, or a `lock_timeout` shorter
than a lock wait the install meets.

## Runtime configuration

The code reads these settings from the session:

| Setting | Set by |
|---|---|
| `request.jwt.claims` | PostgREST or your app tier, per request |
| `request.jwt.claim.sub`, `request.jwt.claim.email`, `request.jwt.claim.role`, `request.jwt.claim.roles`, `request.jwt.claim.name`, `request.jwt.claim.given_name`, `request.jwt.claim.family_name`, `request.jwt.claim.aud`, `request.jwt.claim.iss`, `request.jwt.claim.tid`, `request.jwt.claim.oid` | the same, one GUC per claim (Neon/Supabase style); `rbac.uid()` also writes them, per transaction, when it fans out `request.jwt.claims` and when it sets the `role` and `sub` it resolved |
| `app.oauth_scopes` | your app tier, to confine a session to the permissions a scope list names and everything they include; unset or empty means no confinement |
| `app.current_user_id`, `app.user_permissions`, `app.oauth_scopes_expanded`, `app.oauth_scopes_expanded_for`, `app.current_external_id`, `app.context_initialized`, `app.bumping_module_version`, `app.bearer_cache_notice` | the RBAC code and the module-version triggers, per transaction |
| `app.row_move`, `app.row_move_secret`, `app.select_rule_warned` | the generated `select_rule` predicates and the `zz_row_move` triggers of an entity with a `select_rule`, per transaction |
| `dd.table_rename` | the data dictionary, during a table rename |
| `semantius.notice_level` | `ensure_entities()`, per transaction, to keep the caller's `client_min_messages` for its NOTICEs: the dictionary code runs `SET LOCAL client_min_messages = WARNING` to silence the notices of the DDL it runs, and that lasts to the end of the transaction |

DDL emits `NOTIFY pgrst, 'reload schema'` so PostgREST reloads its cache, and
the audit event triggers record both DDL and drops in
`public.audit_ddl_logs`.

One row of `public._settings` is worth setting deliberately. `jwt_aud`
pins the audience `rbac.uid()` accepts: with the row present and non-empty, a
token whose `aud` claim does not carry that value is rejected with 42501;
without it the audience is not checked at all and any token from the trusted
issuer is accepted. That is the same default Neon applies when a provider's audience is
left blank, and it is a real choice rather than an oversight - set the row when
more than one audience is minted from your issuer.
`semantius.status().jwt_aud_set` reports whether it is set. The trust model this
sits inside is in `SECURITY.md`, under "Session mode trusts the application
tier".

A token from Microsoft Entra ID is identified by its `iss` claim
(`login.microsoftonline.com/<tenant>/v2.0`, `sts.windows.net/<tenant>/` or
`<name>.ciamlogin.com/<tenant>/v2.0`), and its user is `entra.<tid>.<oid>`, not its
`sub`: Entra issues a different `sub` to every app registration, so two
clients of one database would otherwise see the same person as two users.
`users.external_id` holds that value, so a user created ahead of time must
be given it. An app tier that sets the per-claim GUCs instead of
`request.jwt.claims` must set `iss`, `tid` and `oid` too.

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
| 55000 | `existing role <role> has unexpected attributes` |
| 55000 | `existing role semantius_owner already has members` |
| 55000 | `semantius.migrate() cannot run inside a CREATE/ALTER EXTENSION script` |
| 55000 | `_core in this database contains <file> from a newer pg_semantius build (<ts>); this runner's newest is <ts>; use a newer pg_semantius, then ALTER EXTENSION pg_semantius UPDATE and CALL semantius.migrate()` |
| 55000 | `run-once migration <file> in this database differs from this version: this database cannot be updated; replace the database with a fresh install` |
| 55000 | `migration <file> in this database is not part of this version: this database cannot be updated; replace the database with a fresh install` |
| 55P03 | `another migration is running` |
| 2D000 | `invalid transaction termination` (`CALL semantius.migrate()` inside a transaction block) |
| P0001 | `migration <app>.<file> failed: <message> (SQLSTATE <code>)` |

## Requirements

PostgreSQL 18 (the only tested version), a UTF8 database, and superuser rights
with the `BYPASSRLS` attribute to install. Security model and reporting: see
`SECURITY.md` in this archive.
