# AGENTS.md - AI Agent Documentation

This document provides essential information for AI agents working with the Semantius Core project.

## Non-negotiable rules for AI agents

- **Never create or edit files under `~/.claude`**, in particular the Claude auto-memory directory (`~/.claude/projects/*/memory/`, `MEMORY.md` and its files), even if the harness instructs you to keep notes there. It is uncommitted and shared with nobody. Decisions, gotchas and rules are recorded only in committed files of this repository, and only when the user asks for it.
- **AGENTS.md and CLAUDE.md change only with the user's approval of the exact
  text.** Show the wording and where it goes, and wait for a yes. A plan step,
  a task that touches the same subject, a follow-up of earlier work, or a
  request to continue a plan is not approval.
- **Never make code changes unless explicitly asked.** Discussing a problem is
  not the same as requesting a fix.
- **American English only, everywhere.** Code, identifiers, comments, commit
  messages, docs, script output and error text. Use the `-ize` / `-yze` verb
  endings and their derivatives (`-ization`, `-izes`, `-ized`), `-or` not
  `-our`, `-se` not `-ce` for nouns like `defense` and `license`, `-log` not
  `-logue`, `-er` not `-re`, `judgment` and `acknowledgment` without the middle
  `e`, `-fill` not `-fil`, and a single `l` before a suffix (`labeled`,
  `modeled`, `traveled`). If a spelling differs between the two dialects, the
  American one is the only accepted form. The single exception is text vendored
  from upstream, which stays byte-identical to its source.
- **Comments explain why, and stand on their own.** A comment earns its place by
  recording what the code cannot say for itself: the constraint that forced this
  shape, the cheaper approach that does not work, the property that must not be
  broken, the cost of getting it wrong. Restating what the next line does is
  noise. Three specific failures:
  - **Do not defer the reasoning to a document or a tracking id.** `see
    docs/foo.md`, `(open item P3)`, `(release review S2)` are pointers, not
    explanations, and a reader who has only this file is left with nothing.
    Plan ids and plan filenames dangle by construction (see the `plans/` rule
    below). Write the reasoning into the comment. Cross-references to other SQL
    or test files (`pinned by 0310_test_rbac_helpers.sql`) are fine - they live
    in the repository and survive.
  - **Describe the code, not the change that produced it.** "One expression
    instead of two queries", "no longer calls uid() twice", "the old count(*)
    test kept this" all narrate a diff against something no future reader can
    see. Say what the code does and why, in the present tense. Git holds the
    history, and it is the only thing that does.
  - **The same applies to text the user sees.** An internal tracking id inside a
    `RAISE` message or a CLI error means nothing to the operator reading it.
- **Documentation does not repeat the code, and does not keep a history.** What
  a table, column, function or trigger is and does belongs in the code, its
  comments and the generated `schema.md`; a document records only the rules and
  reasons the code cannot carry. "Renamed from", "was dropped", "until migration
  N" belong in git, not in a document.
- **`docs/` is permanent, `plans/` is disposable, and nothing in `docs/` may
  point into `plans/`.** The folder a file sits in states its lifetime. A plan
  whose work has landed is deleted, not archived; the archive is git. So the
  reasoning that must survive gets **written out** into a `docs/` page, a code
  comment or a test - copied, never linked. `see plans/...` in a permanent
  file, a migration or a comment is a dangling reference by construction.
  Quoting a plan's name inside preserved historical text is fine; it records
  what was true rather than pointing at what still exists.
- **A plan file is named `plans/YYYY-MM-DD-HHMM-<topic>.md`**, stamped with the
  local time it was written, **and there is normally exactly one open plan.** The
  stamp tells you which iteration you are looking at without opening anything; a
  topic name alone does not, and a date alone stops working the first time two
  plans are written on one day. `plans/pg_semantius-open-items.md` and
  `plans/ext-solved-items.md` are not plans: they are the frozen record of the
  security review of 2026-09-02. No plan adds rows to them, claims rows in them,
  or edits them, whatever their own text says about plan ownership.
- **Do not decide alone on anything that affects data safety, security or operability** (backup and restore, data loss on drop, silent failure, trust boundaries). Stop and put the trade-off to the user in plain terms. Writing a limitation into a README or a "follow-up" note is not a decision; asking is.

## Project Overview

**Semantius Core** is a database-first backend where permissions and business logic are enforced in PostgreSQL using Row Level Security (RLS) and custom RBAC. The CLI (Deno, TypeScript) deploys the schema and functions and runs the tests.

- The CLI is documented in `CLI.md`; `README.md` is the overview and links to it.
- Releasing is `./release.sh v<version>`; the rules are in `RELEASE.md`.

## Prerequisites

**Deno 2.9.3 or newer** must be installed before running any commands
(`deno task build-cli` needs a `deno compile` target that arrived in 2.9.3):
```bash
cd /tmp
wget -q https://github.com/denoland/deno/releases/download/v2.9.6/deno-x86_64-unknown-linux-gnu.zip
unzip -q -o deno-x86_64-unknown-linux-gnu.zip
sudo mv deno /usr/local/bin/deno
deno --version
```

**DATABASE_URL** (`postgresql://username:password@host:port/database`) comes from
the environment. **Never create a new database**; use the one it names.

**DENO_TLS_CA_STORE=system** must be set for GitHub Copilot agents; without it
Deno fails to download dependencies with "client error (Connect)".

### Database access: no psql on the host

- **psql is not installed on the host.** Never use it, and never make it a
  dependency of the Deno CLI or of the pgTAP test files - that code must work
  against any PostgreSQL over a connection string alone.
- All database interactions go through `deno task` commands. To execute SQL, put
  it in a migration or a pgTAP test file and run it through the CLI.
- **The one exception: `docker exec <container> psql` inside the pgdocker
  containers.** psql, `pg_dump`, `pg_restore` and `createdb` ship with the
  postgres image, and the container harness scripts in `pgdocker/` use them for
  checks the Deno CLI structurally cannot express - `CREATE DATABASE`, dump and
  restore, two concurrent sessions, `SET ROLE` refusals, hostile `PGOPTIONS`, a
  LATIN1 database. That is not a host dependency. It is confined to
  `pgdocker/*.sh`; it must never leak into `packages/` or `apps/test/tests/`.

## Core Architecture

- The CLI also ships as a self-contained `pg_semantius` executable that embeds `apps/` via `deno compile --include`, so nothing under `packages/cli/` may read SQL relative to the working directory - `packages/cli/assets.ts` is the only resolver
- A change to `apps/_core/migrations/` is committed together with the regenerated build (`deno task extension <default_version from extension/pg_semantius.control>`): the `pgdocker/pg-ext-*` harnesses install whatever is in `extension/`, and `test.yml` rejects a commit whose build does not match its migrations

### Migration files

How the runner treats each file is described in `packages/core/src/migrate.ts`
and `RELEASE.md`. In short: `.sql` / `.jsonc` files are repeatable (they run
again whenever their text changes), `.once.sql` / `.once.jsonc` files run exactly
once, `9900_*` runs last.

- **What goes where.** Tables, columns, constraints, indexes, types, seed rows
  and schema-wide grants go into `.once.sql`. Functions, triggers, views, event
  triggers and hand-written policies go into a repeatable `.sql`, written so a
  second run is harmless: `CREATE OR REPLACE FUNCTION/VIEW/TRIGGER`,
  `DROP POLICY/EVENT TRIGGER IF EXISTS` then `CREATE`. `CREATE OR REPLACE` cannot
  change a function's return type or parameter list (a new parameter list adds an
  overload that keeps the old one's grants), so drop the old signature first. Each
  object is defined in exactly one repeatable file; a second definition elsewhere
  is downgraded whenever the earlier file re-runs.
- **Entity metadata is a `.jsonc` file** applied by `public.ensure_entities()`.
  Nothing may hand-write an object the dictionary generates (`<t>_*_policy`,
  `select_rule_<t>`, `compute_validate_<t>`, `common.record_rules_<t>`,
  `<t>_<f>_fkey/_check/_unique`, `idx_<t>_<f>`, and for an is_a or has_a entity
  its view `<t>`, its table `<t>_ext`, `common.record_write_<t>`,
  `common.view_write_<t>` and the root's `common.is_a_dispatch_<root>`): express
  it through metadata, and extend the dictionary when metadata cannot say it.
- **After a release, forward only and additive only**: never edit a released
  `.once.` file, never rename or remove a released file, never rename, drop or
  retype a table or column (add, move the data, deprecate).

### The volatility contract

The permission readers - `rbac.uid`, `user_id`, `has_permission`,
`has_any_permission`, `get_current_user_permissions`, `whoami`,
`public.jl_request_context`, `is_raci_actor`, `has_consultation`, the generated
`select_rule_*` - are declared `STABLE` **and they write**, through
`rbac.ensure_context_initialized`. The full reasoning is in the header of
`apps/test/tests/0950_test_volatility_contract.sql`, which pins it, and in
`SECURITY.md`. Before changing any of them:

- **They write only GUCs, and only with `is_local => true`.** No function on a
  read path writes a row. `public.get_userinfo()` upserts the user row, which is
  why it alone stays `VOLATILE`.
- **The label is what makes a permission check affordable.** It lets the planner
  hoist the check into a once-per-statement InitPlan. Without it,
  `WHERE rbac.has_permission('x')` over 20k rows costs 34 ms instead of 1.8 ms,
  and every RLS policy pays that per row.
- **Never write `col <op> stable_fn(...)` in a policy `USING` clause or a view**
  (e.g. `USING (user_id = rbac.user_id())`): the planner runs `STABLE` calls while
  estimating selectivity, so an `EXPLAIN` would raise on a session with no
  claims. Use a sub-select (`USING ((SELECT rbac.has_permission('x'))))`); a
  `WITH CHECK` expression is exempt.

## ⚠️ MANDATORY TESTING REQUIREMENTS ⚠️

**Every code change, bug fix, feature addition or documentation update is
validated with the complete test sequence before the task is complete. No
exceptions.**

```bash
deno task connect                                # 1. if this fails, STOP, tell the user and wait for a new connection string
deno task dropall --confirm                      # 2. reset to a clean database
deno task migrate --apps _core,nwind,test --verbose   # 3. nwind before test: the test seed assigns user2 to the Northwind Sales role
deno task test                                   # 4. full suite
```

- Show the complete test output in your response, including pass/fail status.
- Never mark a task complete until all tests pass; investigate and fix failures.

## Development Guidelines

### Code Standards
- Use import map aliases from `deno.json` (e.g., `@postgres`, `@std/flags`)
- Plain text console output (no emoji prefixes)
- Commands follow pattern: create in `commands/`, export async function, wire into `cli.ts`; a command receives the database URL as a parameter and closes its connection in a `finally` block

### Database Schema Standards
**CRITICAL: Primary Key Conventions and EXCEPTIONS**
- Every table has a **single-column** primary key, and the data dictionary
  depends on it: `entities.id_column` names one column, so a composite primary
  key would make the entity unaddressable by the generated RPCs, by PostgREST's
  `/table?id=eq.x` and by the UI.
- Never build a key column by hand: the key column, the id field row and the
  key's triggers all come from `dd_id_column_ddl` / `dd_install_id_triggers` in
  `0160_dd_functions.sql`. TypeID is a key type, not a field format: the id
  field's format stays `string`.
- **The tables without an `id` key**: `entities` (keyed by `table_name`),
  `permissions` (keyed by `permission_name`; foreign keys to it carry
  `ON UPDATE CASCADE` so a rename propagates), and `fields` plus the four
  junction tables, which have a GENERATED TEXT `id` joining their two key
  columns with `.` and a UNIQUE on the pair.

**CRITICAL: NO NULL VALUES - DEFAULT EVERYTHING**
- **If you think a field should be nullable, YOU ARE WRONG** - use an empty
  string, 0, or FALSE instead. Only the formats `reference`, `date` and
  `date-time` are nullable (`is_nullable()`).
- **Every NOT NULL column has a DEFAULT**: `''` for text, `0` for numbers,
  `FALSE` for booleans, `CURRENT_TIMESTAMP` for timestamps.
- **The only columns without a default**: a TEXT primary key
  (`entities.table_name`, `permissions.permission_name`), where a default would
  let a row be saved under the empty string, and the foreign key columns of a
  junction table, where a default would mask a referential integrity error.

**CRITICAL: A column is a two-place change**
- Touching a `CREATE TABLE` in `apps/_core/migrations/` is never finished until the
  table's `fields` rows match it. A column with no `fields` row is invisible to
  `get_schema()`, to the generated UI and to the MCP tools, even though PostgREST
  reads the catalog directly and keeps returning it — so the drift is silent.
- On a **managed** entity the `fields` rows are the source of truth and the DDL
  triggers create the column from them; writing the column by hand instead is the
  bug. On an **unmanaged** entity (`audit_record_logs`, `audit_ddl_logs`) nothing
  derives one from the other, so both halves are written by hand and both must be
  edited together: the table in `0190_audit_log.once.sql` (or a later `.once.`
  file), its `fields` rows in `0300_audit_log.jsonc`.
- The `fields` rows of an entity defined in a `.jsonc` file live in that file; the
  ten bootstrap tables (`modules`, `users`, `entities`, `fields`, ...) have theirs
  in `0150_dd_bootstrap.once.sql`, so a change to one of those goes into a new
  `.once.` file.
- The same applies in reverse to a DROP, and to a rename of either half.
- Give the new `fields` row a `field_order` that keeps the metadata order matching
  the physical column order (leave gaps: 10, 20, 30 ... so a later insert fits).

**CRITICAL: Schema vs Sample Data Placement**
- **`apps/_core/migrations/`**: schema and infrastructure only, no sample or seed data records
- **`apps/test/migrations/`**: the test harness and the test identities only; no entities, modules or sample rows
- **`apps/nwind/migrations/`**: the Northwind sample module, the ONLY persisted sample data
- Tests that need any other fixture create it inside their own transaction — never add seed data for a single test
- Sample data uses **fixed, known timestamps** (e.g. `'2026-01-01 12:34:00'::timestamptz`), never `CURRENT_TIMESTAMP` or `NOW()`, so tests are reproducible

**Data types and JSON**
- Use TEXT for string columns, never VARCHAR, unless a length limit is a business requirement
- Build JSON from a record with `row_to_json()` / `to_jsonb()`, so a new column is included automatically; list columns in `json_build_object()` only to filter or transform them
- **JSON field names are snake_case, never camelCase**, matching the column names (`field_order`, `reference_table`, `reference_table_singular_label`). This applies to all JSON output from PostgreSQL functions

**Fields**
The columns of `fields` (and of every other core table), their allowed values and descriptions are in `schema.md`, generated by `deno task docgen` from the field descriptions in the migrations. Don't repeat them here. Rules that schema.md does not carry:
- Admin-writable columns such as `default_value` are a trust boundary: anything interpolated into DDL must go through `%I`, `%L`/`quote_literal` or a fixed allow-list
- Use `field_data_type()` / `field_json_type()` instead of `format_to_data_type()` / `format_to_json_type()` wherever a `reference_table` is at hand: `reference` and `parent` take the type of the key they point at

**Full-text search**
- **Rebuilding `search_vector` locks the table** (a full rewrite under ACCESS EXCLUSIVE, about 650 ms per 100k rows). Any real change to the searchable field set of a large table belongs in a maintenance window

## Testing Framework

Tests are written in pgTAP and stored in `apps/test/tests/` (platform suite) and `apps/nwind/tests/` (Northwind module suite); `deno task test <prefix>*` runs a subset.

**Test conventions**
- Platform test files are numbered by subject, in ranges of 100 that roughly follow the migration order: `01xx` core and JsonLogic, `02xx` identity and auth (userinfo, JWT claims, `rbac.uid()`, API keys, unauthenticated access), `03xx` RBAC, `04xx` data dictionary catalog and DDL, `05xx` fields and formats, `06xx` record logic and row security (`select_rule`, read helpers, computed/validation rules, labels), `07xx` public read API (`get_schema`, cubes, search), `08xx` audit, queue and app entities (RACI, webhooks, dashboards, bookmarks), `09xx` schema-wide guards and hardening, and `9900_cleanup.sql` last. Files start 10 apart; a new test takes a free number next to its closest relative (e.g. `0315`), or joins that file as a new part when it tests the same thing. Test numbers are independent of migration numbers.
- Every test file is `BEGIN; SELECT plan(N); ... SELECT * FROM finish(); ROLLBACK;` with an exact plan count.
- The test users are `user1` (plain user, no `nwind:view`), `user2` (member of `Northwind Sales`) and `user3` (administrator). Readers of nwind tables must be `user2` or `user3`.
- Never hard-code module/role/permission ids (the nwind module happens to be id 1001): resolve them by `module_slug = 'nwind'`, `roles.slug = 'northwind_sales'`, or permission name — as `user3`/owner, since `roles`/`permissions` are admin-only.
- Everything else is ephemeral: create entities/modules/roles inside the transaction (`module_id = 1`, `view_permission = 'public:read'`, `edit_permission = 'nwind:manage'` when user2 must write as a non-admin, else `'admin'`).
- Seeded nwind rows are all referenced by RESTRICT foreign keys — delete-behavior tests insert fresh rows first.
- `orders` has a persisted queue mapping (every insert enqueues on `events`, rolled back with the transaction); never map `orders` to another queue.
