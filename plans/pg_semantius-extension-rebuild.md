# pg_semantius extension rebuild — design

Status: **implemented and green** as version 0.5.0 on 2026-09-03. The spike
gate passed first, then the rebuild was built and verified:

| Requirement | Evidence |
|---|---|
| Backup is a plain `pg_dump`, restore a single-pass `pg_restore` | `pg_restore --exit-on-error` exit 0, no flags; row counts, policies, triggers, event triggers and functions all identical; also green through `-Fp \| psql`, `-j 4` and `-1` |
| `DROP EXTENSION` never causes data loss | no CASCADE needed; every relation, row, policy, trigger and event trigger survives; only the `semantius` schema is removed; `CASCADE` is equally inert |
| Install may take more than one statement | `CREATE EXTENSION pg_semantius;` then `SELECT semantius.migrate();` |

Membership: **4 members** (the `semantius` schema and three functions) against
0.4.0's 74 types, 270 functions, 52 relations, 4 schemas and 3 event triggers;
`extconfig IS NULL`; all 52 core relations are ordinary objects.

Verification runs, all green: `pgdocker/pg-ext-lifecycle.sh` **76 passed, 0
failed**; `pg-ext-retest.sh --coverage` and `pg-cli-retest.sh --coverage` both
**2079 passing, 0 failing** with identical coverage (186/295 functions,
1,816/2,162 statements). A schema-only `pg_dump` of the extension-installed and
the migrate-installed database is **byte-identical** — 22,817 normalized lines
each, zero differences — so the two install paths produce the same database.
The generator is deterministic (two runs byte-identical) and emits LF only.

The gate found one defect in this document, corrected below: the schema could
not be called `pg_semantius`. Option F (detach members with
`ALTER EXTENSION ... DROP`) was tested and rejected; see the options table.

Original status: design, approved shape, not implemented. The owner decisions of
2026-09-03 are recorded in "Decisions" below. Implementation is a separate
step. Companion document: `plans/pg_semantius-open-items.md`, whose rows
marked `extension` this design has to close.

Last updated: 2026-09-03.

## 1. Requirements

The three requirements are absolute; every option below is judged against
them and nothing else.

1. **Backup is a plain `pg_dump`. Restore is a plain single-pass
   `pg_restore`**, on the same cluster or on a fresh one. No flags, no
   environment variables, no extra steps, no ordering rules.
2. **`DROP EXTENSION` never causes data loss.**
3. **Install may take more than one statement.**

## 2. Root cause, stated once

pg_dump treats extension member tables as part of the extension's *code*: the
dump carries `CREATE EXTENSION` and, unless the table is registered with
`pg_extension_config_dump`, none of its rows. Registered rows are then loaded
into tables whose constraints, triggers and seed rows already exist, because
`CREATE EXTENSION` ran in the first step of the restore. pg_dump orders
registered tables by their foreign keys and gives up when it finds a cycle —
it printed exactly that warning for `modules`/`permissions`. Every
data-dictionary trigger fires on the COPY. `DROP EXTENSION` drops members.

Therefore: **no table that holds user data, and no object a user can modify,
may be an extension member.** Because pg_dump emits `CREATE EXTENSION` before
the tables, and because everything an extension script creates becomes a
member, the extension script cannot create the schema at all. It can only
deliver the *code* that creates the schema, plus the cluster-level roles that
a database dump cannot carry.

Everything found this week follows from that one property: the dump skipped
all data until a `pg_extension_config_dump` registry was added; the restore
needs three passes because member tables carry FK cycles and dictionary
triggers that fire during COPY; install-time audit rows collide with restored
rows (worked around with `pg_semantius.skip_audit`); fields added to core
entities are not restored (B16); `DROP EXTENSION` destroys all data.

## 3. Options considered

| Option | Plain dump | Single-pass restore | DROP keeps data | Verdict |
|---|---|---|---|---|
| A. Today: member tables + config-dump registry + three-pass restore + `skip_audit` | yes, with filters | no | no | rejected |
| B. A + a `pg_semantius.restoring` mode in the dictionary triggers + deferrable back-reference FKs + `pg_restore --single-transaction` | yes | one command, still needs `PGOPTIONS` | no | rejected |
| C. Code-only extension (functions and types as members), tables created outside | yes | yes | data yes, but `DROP ... CASCADE` strips every policy and trigger; needs a manual split of the 34 migrations | rejected |
| D. Thin installer: the extension ships the roles, a schema and functions that apply the migrations as ordinary objects | yes | yes | yes — the drop removes the schema and the functions only | **chosen** |
| E. No extension: a plain SQL bundle run with psql | yes | yes | n/a | fallback if PGXN and `ALTER EXTENSION UPDATE` are not wanted |
| F. Today's script, then `ALTER EXTENSION ... DROP TABLE/FUNCTION/...` at the end to detach every object | yes | **no** | yes | rejected — tested 2026-09-03, see below |

**Why F fails, tested rather than argued.** Detaching works: a stub extension
whose script creates a table, seeds it and then runs
`ALTER EXTENSION ... DROP TABLE` leaves that table with zero members, holding
both the seed row and later user data. It would also give a one-statement
install. But `pg_dump` then emits

```
CREATE EXTENSION IF NOT EXISTS detachdemo WITH SCHEMA public;   -- line 26
CREATE TABLE public.demo_t (...)                                -- line 44
COPY public.demo_t (id, note) FROM stdin;                       -- line 56
```

and `pg_restore --exit-on-error` into a fresh database fails with
`ERROR: relation "demo_t" already exists`: replaying `CREATE EXTENSION` re-runs
the whole script, recreating every object it had detached, and the dump's own
`CREATE TABLE` for those now-ordinary objects collides. `IF NOT EXISTS` in the
migrations would not save it — pg_dump's `CREATE TABLE` has none, and past that
the script's seed rows would collide with the `COPY` on the primary key.

Detaching therefore fixes membership but not the restore, because the objects
are still *created* by the extension script. That is the general rule this
design turns on: **the script cannot create the schema at all**, only ship the
code that does. F also needs roughly 400 enumerated `ALTER EXTENSION ... DROP`
statements (52 relations, 270 functions, 74 types, 4 schemas, 3 event
triggers), and anything the generator misses is silently destroyed by
`DROP EXTENSION` and skipped by `pg_dump`. After detaching everything the
extension is an empty shell — option D with extra steps and a worse failure
mode.

**Precedents.** PostgreSQL Anonymizer (`CREATE EXTENSION anon; SELECT
anon.init()`) and pg_tle for the two-statement install; pg_tle and pgsodium
for roles created by the extension script; pgmq for detaching data tables
from membership so that pg_dump works. TimescaleDB, Citus and PostGIS need
pre/post restore hooks precisely because their catalogs are seeded members
with cycles — the class of problem this design removes rather than manages.

**Known drawbacks of D, accepted.**

- `pg_extension.extversion` describes the installer, not the installed
  schema, so `\dx` misleads; `semantius.status()` is the answer.
- PGXN readers expect `CREATE EXTENSION` alone to be complete; the README and
  the release notes must lead with both statements.
- Upgrade scripts are full bundles and must drop members removed since the
  previous version.
- A dump taken *after* `DROP EXTENSION` carries no `CREATE EXTENSION`, so a
  fresh-cluster restore of it needs the roles created first.
- Restoring a database creates cluster-wide roles as a side effect.

## 4. The design

### 4.1 Control file

```
comment = 'Semantius core: RBAC, RLS, data dictionary, and message queue'
default_version = '<version>'
schema = public
relocatable = false
superuser = true
encoding = 'UTF8'
```

- `schema = public`: PostgreSQL then ignores the caller's `search_path` for
  the extension and refuses `CREATE EXTENSION ... SCHEMA other` with
  `extension "pg_semantius" must be installed in schema "public"`. `public`
  always exists, so nothing is auto-created; pg_dump emits
  `CREATE EXTENSION IF NOT EXISTS pg_semantius WITH SCHEMA public`, which
  matches. (`relocatable = false` on its own does *not* refuse
  `SCHEMA other` — it only forbids `ALTER EXTENSION ... SET SCHEMA`
  afterwards.)
- `encoding = 'UTF8'`: 16 migrations contain UTF-8 text.
- **No `requires`.** `CREATE EXTENSION ... CASCADE` would install pgcrypto
  into the caller's default creation schema, and `0110_apikeys.sql` calls
  `gen_random_bytes`, `crypt` and `gen_salt` unqualified under
  `SET search_path = public` — API keys would break in exactly B2's scenario.
  Instead `0010_create_core.sql`'s `CREATE EXTENSION IF NOT EXISTS pgcrypto`
  runs inside `migrate()` under its pinned `SET search_path = public` and
  creates pgcrypto in `public` deterministically. META keeps pgcrypto as a
  runtime prerequisite.

### 4.2 Extension script contents, in order

The script runs on every `CREATE EXTENSION`, including the one inside a
restored dump, so every check here protects the restore as well.

1. **Database encoding check**: `pg_encoding_to_char(encoding) = 'UTF8'` for
   `current_database()`, else raise `55000`. (`encoding = 'UTF8'` in the
   control file alone rejects LATIN1, but a SQL_ASCII database would accept
   raw bytes; the explicit check closes B9 fully.)
2. **Roles and memberships**, idempotent but **asserting**:
   - `authenticated`
   - `semantius_user` + `GRANT semantius_user TO authenticated`
   - `semantius_authenticator NOLOGIN` + `GRANT authenticated TO
     semantius_authenticator WITH INHERIT FALSE, SET TRUE`
   - `semantius_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
     NOREPLICATION NOINHERIT BYPASSRLS` — `0290_owner_hardening.sql`'s
     attribute list with `NOREPLICATION` spelled out (it is the default
     there). A fresh-cluster restore depends on BYPASSRLS existing before
     `OWNER TO semantius_owner` runs.

   When a role already exists its attributes are **verified** and the install
   refuses (`55000`, naming the role and the offending attribute) instead of
   adopting it: `semantius_owner` must be NOSUPERUSER NOLOGIN NOCREATEROLE
   NOCREATEDB NOREPLICATION NOINHERIT BYPASSRLS **with no members**; the
   other three must be NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB
   NOREPLICATION (LOGIN allowed, as `pgdocker/init/10-roles.sql` relies on).
   Otherwise a CREATEROLE user who pre-creates `semantius_owner` with itself
   as a member would own every core table after a restore.

   Roles are shared objects: never members, never dropped by
   `DROP EXTENSION`. They are in the script so that the `CREATE EXTENSION`
   *inside a dump* provisions them before the dump's
   `CREATE POLICY ... TO semantius_user`, `GRANT ... TO authenticated` and
   `OWNER TO semantius_owner` run. LOGIN flags and passwords stay per
   environment (`pgdocker/init/11-session-role.sh`,
   `docker-postgres/initdb/20-authenticator-login.sh`, or
   `pg_dumpall --globals-only`).
3. `CREATE SCHEMA semantius;` — a member, dropped with the extension. Not
   via the control file's `schema` parameter, which would create a
   *non-member* schema that survives `DROP EXTENSION`. No `GRANT USAGE`.
   The schema is `semantius`, **not** `pg_semantius`: PostgreSQL reserves
   the `pg_` prefix for system schemas and refuses
   `CREATE SCHEMA pg_semantius` with `unacceptable schema name` /
   `The prefix "pg_" is reserved for system schemas`. The *extension* may
   keep the `pg_semantius` name (extension names are unrestricted), and so
   may the `pg_semantius.skip_audit` GUC (custom GUC classes are
   unrestricted); only the schema had to move. Found by the spike gate on
   2026-09-03, after this document had specified `pg_semantius` throughout.
4. The functions `semantius.migrate()`, `semantius.pending()`,
   `semantius.version()`, `semantius.status()` and
   `semantius.harden()`.

**Members of the extension: the schema and its functions, nothing else.**

**Generator invariants** — not intent, asserted by the generator, in install
and upgrade scripts alike: after every function it writes, it emits
`REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC`; every function has
`SET search_path` in `proconfig`, `prosecdef = false` and a `COMMENT`;
upgrade scripts emit `DROP FUNCTION IF EXISTS` for every member removed from
the bundle.

### 4.3 `semantius.migrate()`

`LANGUAGE plpgsql`, **not** `SECURITY DEFINER`, so that `current_user`,
`session_user` and the superuser check are the caller's — which
`0010_create_core.sql`, `0050_rbac_rls.sql` and `0290_owner_hardening.sql`
rely on.

Pinned session settings in the function definition:

- `SET search_path = public`
- `SET standard_conforming_strings = on` — `0160_pgmq.sql:65` stores a
  `regexp_replace` with `'\\\1'` in a GENERATED expression; under `off` it
  would be silently corrupted.
- `SET check_function_bodies = on` — the CLI path's behavior.

Body, generated:

1. **Pre-flight**, before anything else so that it also runs on no-op calls,
   each check with a fixed SQLSTATE and a message text quoted in the README:
   - superuser: `(SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname =
     current_user)`, else `42501`. (`is_superuser` follows the outer user,
     not the effective user under a SECURITY DEFINER wrapper; 0290 uses the
     GUC form and is aligned to `rolsuper` in the same change.)
   - `PERFORM set_config('session_replication_role', 'origin', true)` — a
     superuser caller's `replica` would silently disable every dictionary
     trigger during seeding.
   - UTF8 database (`55000`), as in the script.
   - `pg_advisory_xact_lock(hashtext('migrate'))` — the CLI runner's key
     (`packages/cli/commands/migrate.ts:36` uses `pg_try_advisory_lock` on it
     and fails fast), so two installers queue and an installer and the CLI
     conflict correctly.
   - the real `pgmq` extension must not be installed (`55000`); otherwise
     `CREATE OR REPLACE FUNCTION pgmq.*` would silently overwrite pgmq's own
     member functions (B4).
   - an already installed pgcrypto must live in `public` (`55000`, HINT
     `ALTER EXTENSION pgcrypto SET SCHEMA public`).
   - **not inside an extension script**: probe
     `pg_extension_config_dump('pg_catalog.pg_class'::regclass, '')` in a
     sub-block. It raises `feature_not_supported` (`0A000`) outside a script
     (fine) and `55000` inside one — including inside
     `ALTER EXTENSION ... UPDATE` — in which case `migrate()` raises, because
     everything it created would become a member of whatever extension is
     being created.
2. Create `public._versions` with the existing `getVersionsTableSql()` from
   `packages/core/src/migrate.ts` (extended in the same change by a
   `checksum` column, see 4.4), byte-identical to the CLI's.
3. For every `_core` migration, in filename order:

   ```sql
   IF NOT EXISTS (SELECT 1 FROM public._versions WHERE name = '_core.<file>')
   THEN
     RAISE NOTICE 'pg_semantius: applying _core.<file>';
     EXECUTE $pgsem_<file>$ ...verbatim file text... $pgsem_<file>$;
     INSERT INTO public._versions (name, checksum)
       VALUES ('_core.<file>', '<sha256>');
   END IF;
   ```

   Each `EXECUTE` sits in a sub-block whose handler re-raises with the
   migration name, the original SQLSTATE, message, detail, hint and the first
   line of `PG_EXCEPTION_CONTEXT` (the statement position) — a bare failure
   would otherwise report the whole 75 KB migration as CONTEXT.

   The text is embedded **verbatim**: no rewriting, no lifting. The generator
   asserts that neither the per-migration dollar tag nor the outer
   function-body tag occurs anywhere in the bundle, normalizes line endings
   to LF before embedding and before hashing (closes B13), and **lints** each
   migration: no top-level `SET`, `RESET`, `SET ROLE`, `COPY ... FROM STDIN`,
   `CREATE INDEX CONCURRENTLY`, no transaction control. None exist today; a
   `SET` in one migration would persist into the following 33, unlike the
   CLI's per-file transactions.
4. **Post-condition**: no object in `public, common, rbac, audit, pgmq` is a
   member of any extension other than an allow-list (`pgcrypto`, and what the
   coverage harness installs — `plpgsql_check`); raise otherwise. (pgTAP is
   vendored SQL in schema `pgtap`, not an extension.)
5. Closing `RAISE NOTICE` with applied and skipped counts and elapsed time;
   `NOTIFY pgrst, 'reload schema'` once, delivered at commit.

Names in `_versions` are exactly the CLI runner's `${app}.${name}`
(`packages/core/src/migrate.ts:157`), so `deno task migrate` on an
extension-installed database is a no-op and `migrate()` on a CLI-installed
database is a no-op. One function serves install, upgrade and re-run.

It is a **FUNCTION**, not a PROCEDURE with per-migration `COMMIT`: one
transaction, atomic, so a failed install leaves nothing behind; a procedure
that commits cannot carry a `SET` clause, and `CALL` fails inside any
transaction block (`psql -1`, multi-statement strings, most drivers). Today's
`CREATE EXTENSION` already runs all migrations in one transaction and passes
the suite, so the shape is proven. If long upgrades on populated databases
ever need shorter lock windows, add `semantius.migrate_step()` later; the
primary API stays a function.

Fail-closed client settings the README lists: `statement_timeout`,
`lock_timeout`, `default_transaction_read_only`, and any isolation level
above read committed (a second concurrent caller would see a pre-lock
snapshot of `_versions`).

### 4.4 `pending()`, `version()`, `status()`, `harden()`

- `pending()` — the bundled migration names not in `_versions`. Works before
  `_versions` exists.
- `version()` — the bundle version, from `pg_extension.extversion`.
- `status()` — one row: extversion, `_settings.db_version`, applied count,
  pending count, **unknown** `_versions` rows (a dump from a newer bundle
  restored onto an older installer), applied rows whose `checksum` differs
  from the bundle (the Flyway `validate` / sqitch idea; the `checksum` column
  is added to the shared `getVersionsTableSql()` and written by the CLI
  runner too), objects in the five schemas not owned by `semantius_owner`,
  and missing installer default-ACL rows for `current_user`.
- `harden()` — re-runs 0290's block and the 0010/0050 default ACLs for the
  current superuser: the repair after a restore by a differently named
  superuser.

### 4.5 Lifecycle

```sql
CREATE EXTENSION pg_semantius;       -- encoding check, roles, schema semantius, functions
SELECT semantius.migrate();       -- pgcrypto, tables, functions, triggers, policies, seeds
ALTER EXTENSION pg_semantius UPDATE; -- new bundle: CREATE OR REPLACE of the functions
SELECT semantius.migrate();       -- applies the new migrations only
DROP EXTENSION pg_semantius;         -- removes schema + functions; nothing else
```

### 4.6 Backup and restore

`pg_dump` (as a superuser or a BYPASSRLS role — `_versions` and `_settings`
have RLS and pg_dump sets `row_security = off`) dumps every table with its
rows and every function, trigger, policy and event trigger as **ordinary
objects**, in pg_dump's normal order: schemas and `CREATE EXTENSION` first,
then types, functions and tables, then COPY and `setval`, then constraints,
indexes, triggers, foreign keys and RLS policies, then ACLs, then event
triggers last.

COPY therefore runs with no triggers, no foreign keys, no RLS and no event
triggers: the FK cycle, the DDL-performing dictionary triggers and the audit
event trigger cannot interfere. `pg_restore -d newdb appdb.dump` as a
superuser restores it in **one pass**, on the same cluster or a fresh one;
`-Fp` with psql, `-j` and `-1` all work. No seed filters, no `skip_audit`, no
`--disable-triggers`, no `PGOPTIONS`. Fields added to core entities and
relabelled core rows are ordinary data (closes B16).

Documented facts, not steps:

- Restore into an empty database (`createdb -T template0`); do **not** run
  `migrate()` first — the dump's `CREATE EXTENSION` recreates the roles and
  the functions.
- Restore as a superuser named like the installing one (`postgres` in the
  shipped images), and not with `--no-owner`. With a differently named
  superuser, `OWNER TO semantius_owner` still succeeds (the dump's
  `CREATE EXTENSION` recreates the role), but the four schemas and the event
  triggers stay owned by the restorer and the installer's `pg_default_acl`
  rows — including `REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` in `public` —
  are lost, so functions later created by hand are PUBLIC-executable.
  `status()` reports it; `harden()` repairs it. `--no-owner` additionally
  loses 0290's `OWNER TO semantius_owner` and makes the dictionary's
  SECURITY DEFINER code run as the restorer. `SECURITY.md` "What is not"
  gains this case.
- After a fresh-cluster restore the roles exist but are NOLOGIN and without
  passwords; rerun the deployment's login step.
- If the extension files are absent on the target server, the dump's
  `CREATE EXTENSION` and `COMMENT ON EXTENSION` fail, `pg_restore` exits 1
  with those two errors, and everything else restores — the database works
  without the extension (`--exit-on-error` stops instead). On a *fresh
  cluster* without the files the roles are also missing and every
  `OWNER TO`, `GRANT ... TO` and `CREATE POLICY ... TO` fails: create the
  four roles first (`pg_dumpall --globals-only`, or the statements in the
  README).
- A dump taken after `DROP EXTENSION` has no `CREATE EXTENSION`: same rule.
- A dump restored on a server carrying a newer bundle is "pending" until
  `migrate()` runs; on an older bundle `status()` lists the unknown rows.
- `pg_upgrade` needs no script and no file (reasoned, untested; stated as
  such).
- UTF8 databases only.

### 4.7 Upgrade scripts

`pg_semantius--<a>--<b>.sql` is the full extension script minus
`CREATE SCHEMA`, with `CREATE OR REPLACE FUNCTION` (replacing a member of the
same extension inside its own script is allowed) and
`DROP FUNCTION IF EXISTS` for removed members.

Nothing is released, so no migration path from the 0.4.0 member-table build
is written; `extension/versions.json` keeps only the current build and dev
stacks are recreated. The manifest stays for the "released migration edited"
warning and for the `--strict` mode of B7.

Audit side effect: `current_query()` is the *client's* statement, so the DDL
that `migrate()` runs is logged with `query_text` matching
`semantius.migrate()` — about 1,500 small rows on a fresh install, no
longer the whole script as on the CLI path — and an `ALTER EXTENSION UPDATE`
logs its own few statements. The whole-script `query_text` problem (P6)
becomes CLI-path only.

### 4.8 Uninstall recipe (B6), in this order

1. `DROP EXTENSION pg_semantius;`
2. `DROP EVENT TRIGGER track_ddl_changes, pgrst_ddl_watch, pgrst_drop_watch;`
   — first, because they fire on every drop below and write into tables that
   are being dropped.
3. `DROP OWNED BY semantius_owner CASCADE;` — 0290 made it the owner of every
   core object and every dictionary table; this removes its default ACLs and
   grants and **deletes all Semantius data**.
4. `DROP SCHEMA IF EXISTS common, rbac, audit, pgmq CASCADE;`
5. `DROP TABLE IF EXISTS public._versions;`
6. Undo the installer's default ACLs in `public`:
   `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, INSERT, UPDATE,
   DELETE ON TABLES FROM semantius_user;` … `REVOKE USAGE, SELECT ON
   SEQUENCES FROM semantius_user;` … `GRANT EXECUTE ON FUNCTIONS TO PUBLIC;`
7. `DROP OWNED BY semantius_user, authenticated, semantius_authenticator;`
   (revokes the `public` schema ACL).
8. `REVOKE semantius_user FROM <installer>;` for databases installed before
   B11.
9. Only if no other database in the cluster uses them:
   `DROP ROLE semantius_user, authenticated, semantius_authenticator,
   semantius_owner;`
10. Optionally `DROP EXTENSION pgcrypto;`

No automatic `uninstall()` function: dropping user data is the owner's
explicit act.

### 4.9 What stays exactly as it is

The migrations (verbatim). The CLI migrate path. The Neon and Supabase
deployments. The pgTAP suite semantics — both install layouts produce
identical ordinary objects, proven by the equivalence step (§7, step 10).

## 5. Open items the rebuild closes

Every `extension` row of `plans/pg_semantius-open-items.md`, plus the rows
this design touches.

| Item | How the rebuild addresses it | Proven by |
|---|---|---|
| B2 schema pinning | `schema = public` in the control file: the caller's search_path is ignored for the extension and `SCHEMA other` is refused with PostgreSQL's own message. `migrate()` runs the migrations under its own pinned `search_path = public`; pgcrypto is created by `0010` inside `migrate()`, in `public`, never by `CASCADE`; the pre-flight refuses a pgcrypto that lives elsewhere. | §7 step 6 |
| B6 drop leftovers, CASCADE | `DROP EXTENSION` removes the schema and the functions; it never needs CASCADE and never touches data or policies. The ordered uninstall recipe (§4.8) covers every leftover the row lists: roles and memberships, the two default-ACL entries, the `public` schema ACL, pgcrypto. The `GRANT semantius_user TO current_user` in `0010:35` that leaves `postgres` a member is fixed in the migration (B11). | §7 steps 4, 4b |
| B7 release workflow | No separate workflow and no pull request (owner, 2026-09-03): the whole gate lives in `extension-release.yml`, on the tag. It runs `deno task extension <version>`, then fails on any `git status --porcelain -- extension/` difference (not `git diff`, which misses the generator's new upgrade scripts and pruned full installs), then `pg-ext-retest.sh` and `pg-cli-retest.sh` — all before packaging, releasing or pushing the image. The guard and both suites are in place since 2026-09-03; this rebuild adds `pg-ext-lifecycle.sh` to the same job and the `pgxn_meta` validation. Generator `--strict` (a new flag in `packages/cli/cli.ts`) fails on edited or removed released migrations, for use once a version is real. `versions.json` hashes are computed on LF-normalized text so a local build and the runner's agree. | §7 step 11 |
| B8 consumer README | `buildReadme` emits a consumer README only: install (two statements, no CASCADE), upgrade (two statements, `pending()`, `status()`), plain backup and restore with §4.6's documented facts, the uninstall recipe, the four roles with their attributes and the NOLOGIN note, the GUC contract (`request.jwt.*`, `app.*` including `app.bearer_cache_notice`, `dd.table_rename`), the pinned and the fail-closed session settings, the `pgrst` NOTIFY channel, event-trigger side effects, default privileges binding to the installing role and the same-named superuser rule, UTF8 only, pgcrypto in `public`, the PostgreSQL floor (18 — the only tested version, `SECURITY.md:94`; META `prereqs` say the same; a 16 matrix leg in `test.yml` may lower it later), every error text with its SQLSTATE (B15), and a link to `SECURITY.md`. Maintainer notes move to the repo README. No repo-only paths. | A grep of the README against every GUC the migrations read finds each one |
| B9 encoding | `encoding = 'UTF8'` in the control file **plus** the explicit `pg_encoding_to_char` check in the script and in `migrate()` (`55000`): LATIN1 and SQL_ASCII both refuse. | §7 steps 9, 9b |
| B10 META | `https://github.com/semantius/semantius.git`, maintainer with email, `release_status: 'testing'` until the first real release, a `Changes` file generated from a hand-maintained `extension/CHANGES.md` (no build date, so the B7 diff holds), META validated with `pgxn_meta validate` in `test.yml`; the release notes read `CREATE EXTENSION pg_semantius; SELECT semantius.migrate();`. | §7 step 11 |
| B13 line endings | The generator normalizes every embedded migration and every emitted file to LF, and hashes the normalized text. | B7's diff |
| B15 non-superuser | `superuser = true` stays (the script creates roles). `SET ROLE authenticated; SELECT semantius.migrate()` fails with `42501 permission denied for schema semantius`; a role granted USAGE and EXECUTE hits the `rolsuper` check and gets the fixed `42501` message. The README quotes all three texts: PostgreSQL's `Must be superuser to create this extension`, the schema text, and the custom message. | §7 step 8 |
| B16 core-entity customizations | Ordinary tables: custom columns and their `fields` rows are plain data. | §7 step 2 |
| B4 real pgmq present | Fail-fast in `migrate()`'s pre-flight and, for the CLI path, at the top of `0160`, both `55000`; delete the dead `extname = 'pgmq'` schema guard (`0160:10-17`) and the stale comment (`0160:78-81`). | §7 step 7 |
| B5 event-trigger noise | Mechanism unchanged. Its Problem text is corrected: the extension install logs its DDL again, with `query_text` matching `semantius.migrate()`; R1's old "empty audit log" check is replaced. Stays a migration item. | §7 step 1 |
| B11 test artifacts | Fixed in the migrations: skip `GRANT semantius_user TO current_user` (`0010:35`) and `GRANT USAGE ON SCHEMA common TO CURRENT_USER` (`0012:100`) when the current user is a superuser; `RAISE EXCEPTION` instead of the BYPASSRLS `ASSERT` (`0050:14-20`). Done when, after a superuser install, `pg_auth_members` has no `postgres` → `semantius_user` row and `common` has no ACL entry for the installer, and the BYPASSRLS check is independent of `plpgsql.check_asserts`. | tests 0430 and 0060 green; §7 step 1b |
| R1 lifecycle script | `pgdocker/pg-ext-lifecycle.sh`, the steps of §7. | Green on the rebuilt extension |
| R2 CI | Folded into B7: the suite runs in the release job on the tag, development testing stays local and uncommitted. | A tagged release refuses to publish when either suite fails |
| P6 | Confined to the CLI path; the row's text is updated. | none here |
| S14, S15, S17 | Premises unchanged; S14 via B8's `SECURITY.md` link; S17's only touchpoint is the explicit `REVOKE` on the `semantius` functions. | none here |

### New rows for the open-items list, created by the rebuild

- the two-statement install in `pgdocker/init-ext/20-extension.sql` and
  `docker-postgres/initdb/10-install-extension.sql`;
- the coverage universe in `packages/cli/commands/coverage.ts:479-632`
  (derived from extension membership today, so it would be empty — use the
  schema universe on both layouts);
- the readiness gates and stale header comments in
  `pgdocker/pg-ext-retest.sh:60` and `docker-compose/test.sh:152` (wait for
  `_versions`, not only for the `pg_extension` row);
- `apps/test/tests/0240_test_no_unsafe_functions.sql` widens to the core
  functions on the extension path (already green on the migrate path) and
  gains the `semantius` schema — today it excludes extension members;
- the `checksum` column in `getVersionsTableSql()` and the CLI runner;
- `SECURITY.md:41` ("drop of the extension") and the `--no-owner` case in
  "What is not";
- `docker-compose/README.md:16` wording;
- `0290_owner_hardening.sql` aligned to the `rolsuper` check.

## 6. Consequences for existing code

- `packages/cli/commands/extension.ts`: emit the installer script instead of
  the concatenation; delete `renderSkipAudit`, `renderVersionsSeed`,
  `renderVersionsTable`, `liftExtensionDependencies` and the config-dump
  call; hash normalized text; the migration lint; the per-function
  `REVOKE`/`COMMENT` invariants; the removed-member `DROP`; `--strict`. Keep
  the manifest, control-file, Makefile, META and README generation.
- `packages/cli/commands/extension-dump.ts`: delete. Any surviving
  `pg_extension_config_dump` call reached from `migrate()` is a hard error at
  runtime.
- `packages/cli/cli.ts`: the `--strict` flag.
- `packages/core/src/migrate.ts`: the `checksum` column in
  `getVersionsTableSql()`, written by `executeMigrations`; the three
  `packages/*/src/migrations-bundle.ts` consumers follow
  (`deno task bundle-sql`, i.e. `scripts/bundle-sql.ts`).
- `apps/_core/migrations/0150_audit_log.sql`: remove the `skip_audit` gate —
  0150 returns to its released content. `0160_pgmq.sql`: pgmq fail-fast, the
  dead guard and the stale comment removed. `0010_create_core.sql`,
  `0012_create_cache.sql`, `0050_rbac_rls.sql`: B11.
  `0290_owner_hardening.sql`: the `rolsuper` check.
- `apps/test/tests/0440_test_config_dump.sql`: replaced by the membership
  invariant test — members are exactly the schema and its functions; no
  relation or function in the five core schemas belongs to any extension but
  the allow-list; `extconfig IS NULL`;
  `extnamespace = 'public'::regnamespace` and `extrelocatable = false`; every
  function in `pg_semantius` has no PUBLIC EXECUTE, `prosecdef = false`,
  `search_path` in `proconfig` and a comment;
  `has_schema_privilege('public', 'semantius', 'USAGE')` is false; the
  `_core.*` names in `_versions` equal the bundle exactly and `pending()` is
  empty; `SET ROLE authenticated` then `migrate()` raises `42501`; a probe
  role with USAGE and EXECUTE gets the superuser message; `SET LOCAL
  pg_semantius.skip_audit = on` as superuser followed by an insert is still
  audited (pins the 0150 revert); `DROP EXTENSION` inside
  `BEGIN ... ROLLBACK` (it is fully transactional) followed by assertions
  that tables, rows, functions, triggers, policies and event triggers still
  exist — joining `pg_namespace` by name, not by `::regnamespace`. CLI path:
  skip pattern.
- `pgdocker/pg-ext-dump-restore.sh`: folded into the lifecycle script as the
  single-pass restore step. `pgdocker/pg-ext-lifecycle.sh` (new): §7.
- `.github/workflows/extension-release.yml`: add `pg-ext-lifecycle.sh` and the
  `pgxn_meta` validation to the existing gate, plus `Changes` and the release
  notes. No new workflow file.
- `pgdocker/init-ext/20-extension.sql`,
  `docker-postgres/initdb/10-install-extension.sql`:
  `CREATE EXTENSION pg_semantius;` then `SELECT semantius.migrate();`.
- `pgdocker/pg-ext-retest.sh`, `docker-compose/test.sh`: readiness gates.
- `packages/cli/commands/coverage.ts`: the schema universe always.
- Docs: the generated `extension/README.md`; root `README.md:181-252`;
  `pgdocker/README.md:301-412`; `docker-postgres/README.md`;
  `docker-compose/README.md:16`; `SECURITY.md:41` and "What is not";
  `docs/pg_semantius-test-coverage.md`; `docs/bearer-mode-status.md:161`.
- `plans/pg_semantius-open-items.md`: the rows per §5, plus the new rows.

## 7. Verification before the rebuild is called done

`pgdocker/pg-ext-lifecycle.sh` on the extension stack, non-interactive, every
exit code checked. Tools: psql, pg_dump, pg_restore and createdb inside the
container; Deno on the host; docker. Files are placed with `docker cp` plus
`docker exec -u root cp` into `/usr/share/postgresql/18/extension/` (the
image has no PGXS). Fixtures the script ships: a stub `pgmq` extension
(control file plus a script creating schema `pgmq` and `pgmq.meta`) and a
throwaway extension whose script calls `semantius.migrate()`.

**0. Preflight.** The control file has `schema = public`,
`encoding = 'UTF8'`, `superuser = true` and no `requires`; the generated
script contains no `pg_extension_config_dump`; `META.json` validates when
`pgxn_meta` is on PATH (mandatory in CI).

**1. Fresh install.** `CREATE EXTENSION` (no CASCADE): `pending()` returns
all bundled names and `version()` works before any `_versions` table exists.
Then `migrate()`: `pending()` empty; `version()` equals the control file;
`pgcrypto.extnamespace = 'public'`; the pgTAP suite green; `migrate()` again
is a no-op; `deno task migrate --apps _core` is a no-op; `pg_depend` shows
exactly the schema and its functions; `extconfig IS NULL`; every
`audit_ddl_logs` row has `query_text ~ 'pg_semantius\.migrate\(\)'` and
`count(DISTINCT query_text) = 1`; `status()` reports no drift.

**1b. Second database on the same cluster** (the roles pre-exist):
`CREATE EXTENSION` and `migrate()` succeed; `pg_auth_members` has no
`postgres` → `semantius_user` row (B11).

**1c. Concurrency.** Session A holds `BEGIN; SELECT semantius.migrate();`
open on a fresh database; session B's `migrate()` blocks; A commits; B
returns as a no-op; the `_versions` count equals the bundle.
`deno task migrate --apps _core` during a held `migrate()` exits with its
lock message.

**1d. Transaction shape.** `psql -1 -c "CREATE EXTENSION pg_semantius" -c
"SELECT semantius.migrate()"` succeeds; on another fresh database
`BEGIN; SELECT semantius.migrate(); ROLLBACK;` leaves no `_versions`, no
schema `common`, and the roles present.

**2. Dump and single-pass restore.** Add a custom field to `users` and a
custom entity with rows; `pg_dump -Fc` as `postgres`;
`pg_restore --exit-on-error` in ONE pass into `createdb -T template0` on the
same cluster, run as `docker exec <c> env -i PATH=... pg_restore -U postgres
...` (empty environment, peer auth). Row counts of every table in the five
core schemas and of every dictionary table identical; `pg_policies` count
identical; the custom column and its `fields` row present; the suite green on
the restored database.

**2b. Restore variants** on the same dump: `-Fp` piped to
`psql -v ON_ERROR_STOP=1`; `pg_restore -j 4`; `pg_restore -1`. After each:
`pending()` empty, `migrate()` a no-op, `deno task migrate --apps _core` a
no-op. Recorded, not failed: `--no-owner` leaves owners equal to the restorer
and `status()` reports the drift; restoring into a database where `migrate()`
already ran fails with duplicate-object errors.

**3. Fresh cluster.** The same dump into a second `postgres18-ext:local`
container without the init mounts, port published. With
`POSTGRES_USER=postgres`: exit 0, the same comparison, and tests 0430, 0060,
0240 green there. With `POSTGRES_USER=admin` and no `--exit-on-error`: every
error matches `role "postgres" does not exist`, `status()` reports the
ownership and default-ACL drift, `harden()` clears it (recorded).

**4. Drop.** `DROP EXTENSION pg_semantius` without CASCADE succeeds; every
table, row, function, trigger, policy and event trigger still present; the
suite green without the extension; `DROP EXTENSION ... CASCADE` on a copy is
equally inert; `CREATE EXTENSION` again produces exactly the script's own
`audit_ddl_logs` rows (`query_text ~ 'CREATE EXTENSION'`); `migrate()` a
no-op.

**4b. Uninstall recipe** on the step-3 fresh container, on a database with a
dictionary table: afterwards `pg_default_acl` empty, `pg_event_trigger`
empty, no schema but `public`, `public.nspacl` default, `pg_extension` holds
only `plpgsql`, the four roles gone; then step 1 succeeds again on that
database.

**4c. Upgrade.** From a temp CWD holding a copy of `apps/_core` with one
dummy migration appended and a copy of `extension/versions.json` (otherwise
no upgrade script is written, `extension.ts:181-233`): `deno task extension
<v+1>`; copy the files in; `ALTER EXTENSION pg_semantius UPDATE`; `pending()`
returns exactly the dummy; `migrate()` applies only it; `version()` is
`<v+1>`; the function ACL checks of step 8 hold again.

**4c-b. Cross-version.** The step-2 dump restored on the `<v+1>` server:
`pending()` = dummy, `migrate()` applies only it. A `<v+1>` dump restored on
the `<v>` server: `pending()` empty, `status()` lists the dummy as unknown.

**4d. Failure atomicity and diagnostics.** A `<v+1>` bundle whose dummy
migration fails midway: `migrate()` raises with the migration name, the
original SQLSTATE and message; `_versions` unchanged; `pending()` still lists
the dummy; on a fresh database no schema `common` exists afterwards.

**5. Extension files removed** (same cluster): `pg_restore` without
`--exit-on-error` reports exactly the `CREATE EXTENSION` and
`COMMENT ON EXTENSION` errors, everything else restores, the database is
functional, `pending()` absent.

**5b. Dump taken after `DROP EXTENSION`,** restored on a fresh cluster: fails
only on role references; after `pg_dumpall --globals-only` is applied first
it succeeds and the `pg_auth_members` rows for the four roles equal the
source.

**6. Schema pinning.** `ALTER DATABASE ... SET search_path = other, public`;
`CREATE EXTENSION`; `migrate()`; `pgcrypto.extnamespace = 'public'`; the
API-key tests (0260) green; `CREATE EXTENSION pg_semantius SCHEMA other`
refused with the schema message. (The suite itself sets `search_path` in
`packages/cli/commands/test.ts:306`, so only these assertions count.)

**6b. Hostile session settings.** Install under `PGOPTIONS='-c
standard_conforming_strings=off -c check_function_bodies=off -c
DateStyle=German -c IntervalStyle=sql_standard -c
default_transaction_isolation=serializable'`, and once more with
`session_replication_role=replica`; the step-10 signature equals the plain
install's.

**7. Conflicting extensions.** Install with the stub `pgmq` present stops
with the `55000` message; the throwaway extension whose script calls
`migrate()` fails; a pgcrypto pre-installed in another schema is refused with
the HINT.

**8. Privileges.** `SET ROLE authenticated; SELECT semantius.migrate()`
raises `42501`; `has_function_privilege('public', f, 'EXECUTE')` false and
`prosecdef = false` for every function in `semantius`;
`has_schema_privilege('public', 'semantius', 'USAGE')` false; a probe role
with USAGE and EXECUTE gets the superuser message.

**8b. Role squatting.** As a CREATEROLE non-superuser,
`CREATE ROLE semantius_owner LOGIN; GRANT semantius_owner TO <self>`;
`CREATE EXTENSION` is refused with the attribute message. (A pre-existing
`authenticated LOGIN` is accepted, as `pgdocker/init/10-roles.sql` already
relies on.)

**9. LATIN1** database (`createdb -T template0 -E LATIN1 --locale=C`):
`CREATE EXTENSION` refuses.

**9b. SQL_ASCII** database: `CREATE EXTENSION` refuses with the `55000`
message.

**10. Equivalence.** `pg_dump -s` of the CLI-installed and of the
extension-installed database with a fixed `--restrict-key` (PG 18 emits
`\restrict` lines), minus the `semantius` schema, `_versions` and the
`CREATE`/`COMMENT ON EXTENSION pg_semantius` lines: byte-identical.

**11. Harnesses.** Both harness paths green with `--coverage`; the coverage
universe non-empty on the extension path; `git diff --exit-code extension/`
after generation.

**12. Cleanup** of the databases and of the second container.

**What `pg-ext-lifecycle.sh` implements today** (76 assertions, all green):
steps 0, 1, 1b, 1c, 1d, 2, 2b, 4, 4b, 6, 6b, 7, 8, 8b, 9, 9b, 10, 12.

**Not yet implemented, and stated as such rather than implied:**

| Step | Why it is still open |
|---|---|
| 3. fresh-cluster restore | needs a second container without the init mounts; the same-cluster restore (step 2) covers the mechanism, and a fresh cluster additionally exercises role creation from the dump's `CREATE EXTENSION` |
| 4c, 4c-b. upgrade and cross-version | needs a `<v+1>` bundle generated from a temp copy of `apps/_core` plus `extension/versions.json`; nothing is released yet, so there is no upgrade path to protect |
| 4d. failure atomicity | needs a deliberately broken migration in a `<v+1>` bundle |
| 5, 5b. extension files absent | needs the files moved aside between dump and restore |

They are worth adding before a real release; none of them gates the three
requirements, which steps 2, 4 and 1 prove directly.

**Spike first.** Before the generator work, wrap today's bundle into a
hand-written `migrate()` and run steps 1, 2, 4 and 6b. It costs about an hour
and validates the facts everything rests on: nothing created by `migrate()`
is a member; the single pass restores; `DROP EXTENSION` is inert; the pinned
settings hold.

## 8. Risks

- **Diagnostics.** A failing migration inside `EXECUTE` reports the whole
  text as CONTEXT unless each `EXECUTE` is wrapped — designed in (§4.3).
- **Client timeouts** abort the atomic install; nothing is half-applied.
- **Restore by a differently named superuser, or with `--no-owner`.** See
  §4.6; `status()` detects it, `harden()` repairs it.
- **CVE-2022-2625.** "An extension is not allowed to replace an object it
  does not own" means any `CREATE ... IF NOT EXISTS` or `CREATE OR REPLACE`
  against a pre-existing non-member object *inside the extension script*
  fails. The script creates only the schema and its own functions; roles are
  not objects the rule covers.
- **Logical replication** subscribers never see the dictionary's physical
  tables (DML triggers do not fire there): pre-existing, out of scope, noted.
- **`pg_upgrade`** behavior is reasoned, not tested; stated as such until a
  verification step exists.

## 9. Decisions

Taken by the owner on 2026-09-03:

1. Shape: the thin installer extension (option D). Two statements to install.
2. `pg_semantius.skip_audit` in `0150_audit_log.sql`: removed; 0150 returns
   to its released content.
3. This step delivers the document only; no code changes.
