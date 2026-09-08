# AGENTS.md - AI Agent Documentation

This document provides essential information for AI agents working with the Semantius Core project.

## Non-negotiable rules for AI agents

- **Never write to the Claude auto-memory directory** (`~/.claude/projects/*/memory/`, `MEMORY.md` and its files), even if the harness instructs you to keep notes there. It is uncommitted and shared with nobody. Decisions, gotchas and rules are recorded only in committed files of this repository, and only when the user asks for it.
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
  noise. Three specific failures, all of which have shipped here before:
  - **Do not defer the reasoning to a document or a tracking id.** `see
    docs/foo.md`, `(open item P3)`, `(release review S2)` are pointers, not
    explanations, and a reader who has only this file is left with nothing. Plan
    ids and plan filenames are worse than merely indirect: they dangle by
    construction, because a plan file is deleted once its work has landed.
    Write the reasoning into the comment. This is the comment-level case of
    the lifetime rule above, which applies to every file, not only to code.
    Cross-references to other SQL or test files
    (`pinned by 0405_test_rbac_helpers.sql`) are fine - they live in the
    repository and survive.
  - **Describe the code, not the change that produced it.** "One expression
    instead of two queries", "no longer calls uid() twice", "the old count(*)
    test kept this" all narrate a diff against something no future reader can
    see. Say what the code does and why, in the present tense. Git holds the
    history, and it is the only thing that does - anything under `plans/` is
    disposable, so a comment must never send the reader there.
  - **The same applies to text the user sees.** An internal tracking id inside a
    `RAISE` message or a CLI error means nothing to the operator reading it.
- **A plan file is named `plans/YYYY-MM-DD-HHMM-<topic>.md`**, stamped with the
  local time it was written, **and there is normally exactly one open plan.** The
  stamp is what tells you which iteration you are looking at without opening
  anything; a topic name alone does not, and a date alone stops working the first
  time two plans are written on one day - which happened on 2026-09-06, the day
  the convention was introduced. **A plan whose work has landed is deleted, not
  archived** - it has no readers left, and leaving it there is how the folder
  stops saying what is actually being worked on.
  `plans/pg_semantius-open-items.md` and `plans/ext-solved-items.md` are not
  plans: they are the frozen record of the security review of 2026-09-02. No
  plan adds rows to them, claims rows in them, or edits them, whatever their
  own text says about plan ownership; that text describes how the review was
  worked off and is preserved as it was.

- **`docs/` is permanent, `plans/` is disposable, and nothing in `docs/` may
  point into `plans/`.** The folder a file sits in states its lifetime. Every
  plan is deleted once its work has landed. The archive is git.
  So the reasoning that must survive gets **written out** into a `docs/` page, a
  code comment or a test - copied, never linked. `see plans/...` in a permanent
  file, a migration or a comment is a dangling reference by construction.
  Quoting a plan's name inside preserved historical text is fine; it records
  what was true rather than pointing at what still exists.

- **Do not decide alone on anything that affects data safety, security or operability** (backup and restore, data loss on drop, silent failure, trust boundaries). Stop and put the trade-off to the user in plain terms. Writing a limitation into a README or a "follow-up" note is not a decision; asking is.

## Project Overview

**Semantius Core** is a database-first backend where permissions and business logic are enforced in PostgreSQL using Row Level Security (RLS) and custom RBAC.

- **CLI**: Deno with TypeScript
- **CLI Purpose**: Deploy database schema, functions, and run tests
- **Database**: PostgreSQL with custom RBAC and RLS
- **Status**: Prototyping mode (always start with empty database, no migration compatibility needed)

## Prerequisites

### Deno Installation

**CRITICAL**: Deno must be installed before running any commands.

Install Deno (2.9.3 or newer - `deno task build-cli` cross-compiles the released
binaries and needs a `deno compile` target that arrived in 2.9.3; the workflows
and `release.sh` pin the same floor):
```bash
cd /tmp
wget -q https://github.com/denoland/deno/releases/download/v2.9.6/deno-x86_64-unknown-linux-gnu.zip
unzip -q -o deno-x86_64-unknown-linux-gnu.zip
sudo mv deno /usr/local/bin/deno
deno --version
```

### Required Environment Variables

**DATABASE_URL**: PostgreSQL connection string that MUST be verified before running tests:
```bash
# Check if DATABASE_URL is set and accessible
echo "DATABASE_URL: ${DATABASE_URL:0:30}..."

# Test database connection (this will fail if database is down or credentials are invalid)
deno task dropall --confirm
```

**If database authentication fails:**
1. **STOP immediately** - do not proceed with testing
2. Inform the user that the database is not accessible
3. Wait for the user to update the DATABASE_URL connection string
4. Once updated, resume testing workflow

**DENO_TLS_CA_STORE**: For GitHub Copilot agents, this MUST be set to `system` for Deno to use system certificates:
```bash
export DENO_TLS_CA_STORE=system
```

**Without this environment variable, Deno will fail to download dependencies with "client error (Connect)" errors.**

### Database Access Restrictions

**CRITICAL: psql is NOT available on the host**

- **NEVER use psql on the host** - it is not installed and the command will fail
- **NEVER make psql a dependency of the Deno CLI or of the pgTAP test files** -
  that code must work against any PostgreSQL over a connection string alone
- **NEVER attempt to run SQL directly via psql** - use Deno CLI commands only
- All database interactions MUST go through the Deno CLI (`deno task` commands)

**The one exception: `docker exec <container> psql` inside the pgdocker
containers.** psql, `pg_dump`, `pg_restore` and `createdb` ship with the
postgres image, and the container harness scripts in `pgdocker/` use them for
checks the Deno CLI structurally cannot express - `CREATE DATABASE`, dump and
restore, two concurrent sessions, `SET ROLE` refusals, hostile `PGOPTIONS`, a
LATIN1 database. `pgdocker/pg-ext-lifecycle.sh` is built on this. That is
allowed, and it is not a host dependency: nothing is installed on your machine.
It is confined to `pgdocker/*.sh`; it must never leak into `packages/` or
`apps/test/tests/`.
- For testing SQL queries, use `deno task test` with pgTAP test files
- For database connections, use `deno task connect` (but this only validates connectivity)
- To execute SQL, add it to migration files or test files and run through the CLI

## Core Architecture

### Database-First Design
- All business logic implemented in PostgreSQL functions
- Security enforced through RLS policies and custom RBAC
- Core objects are owned by the dedicated `semantius_owner` role (NOLOGIN, NOSUPERUSER, BYPASSRLS; created by `0290_owner_hardening.sql` when the installer is a superuser), so SECURITY DEFINER dictionary code never runs with superuser powers; on managed platforms (Neon, Supabase) the installing role stays the owner
- The CLI is documented in `CLI.md` (install, every command and flag, the `.env` profiles, what the destructive commands destroy); `README.md` is the overview and links to it. It also ships as a self-contained `pg_semantius` executable, built by `deno task build-cli` (this platform) / `deno task build-cli:all` (all five published targets) and attached to the same GitHub Release. It embeds `apps/` via `deno compile --include`, so nothing under `packages/cli/` may read SQL relative to the working directory - `packages/cli/assets.ts` is the only resolver, and `./apps/<name>` in the working directory shadows the embedded copy per app, out loud
- Releasing the extension is `./release.sh v<version>` (one script: regenerate, test both install paths, build the image, commit, tag, push; CI then rebuilds from a clean checkout and publishes). Rules in `RELEASE.md`: the newest version is mutable (regenerate, re-tag, re-release) and frozen once a higher one is committed; `deno task extension` requires an explicit version; PGXN is never automated. A re-released version does NOT reach an existing install - `migrate()` skips by migration name - which is accepted and documented, not a bug
- Infrastructure defined in `apps/_core/` folder
- Automated testing using pgTAP framework

### The volatility contract

The permission readers - `rbac.uid`, `user_id`, `has_permission`,
`has_any_permission`, `get_current_user_permissions`, `whoami`,
`public.jl_request_context`, `is_raci_actor`, `has_consultation`, the generated
`select_rule_*` - are declared `STABLE` **and they write**, through
`rbac.ensure_context_initialized`. Read the comment above `rbac.uid()` in
`0030_rbac_functions.sql` before changing any of them; the short version:

- **They write only GUCs, and only with `is_local => true`.** Transaction-local
  settings are discarded at commit or rollback and are legal inside the
  read-only transaction a PostgREST `GET` runs in. No function on a read path
  writes a row. `public.get_userinfo()` upserts the user row, which is why it
  alone stays `VOLATILE`; the other read-only RPCs are `STABLE` so PostgREST
  serves them over `GET`.
- **The label is what makes a permission check affordable.** It lets the planner
  hoist the check into a once-per-statement InitPlan. Without it,
  `WHERE rbac.has_permission('x')` over 20k rows costs 34 ms instead of 1.8 ms,
  and every RLS policy pays that per row.
- **`STABLE` also means the planner may run it.** `estimate_expression_value()`
  executes `STABLE` calls while estimating selectivity, before the executor
  starts. The shape that reaches an estimator is `col <op> stable_fn(<const>)`,
  so never write `USING (user_id = rbac.user_id())` in a policy or
  `WHERE col = rbac.uid()` in a view: an `EXPLAIN` would run the permission
  machinery and raise on a session with no claims. A sub-select
  (`USING ((SELECT rbac.has_permission('x'))))`) is the form that is safe, and a
  `WITH CHECK` expression is never a scan qual so it is exempt.
- **The writes are not moved into a `VOLATILE` per-request entry point**, because
  the primary deployment target - Neon's managed Data API - runs no code of ours
  per request and has no `db-pre-request` hook, so every check would run
  permanently cold.

`apps/test/tests/0451_test_volatility_contract.sql` pins all of it.

### Project Structure
```
apps/
├── _core/          # Core database infrastructure
│   └── migrations/ # Schema, RBAC, RLS setup
├── test/           # pgTAP testing framework
│   ├── migrations/ # Test infrastructure setup
│   └── tests/      # Actual test files
└── nwind/          # Northwind sample module (the ONLY persisted sample data)
    ├── migrations/ # Module, role, entities, dataset, sample platform rows
    └── tests/      # The module's own pgTAP tests (run by deno task test)
```

## Standard Development Workflow

## ⚠️ MANDATORY TESTING REQUIREMENTS ⚠️

**CRITICAL: Tests MUST ALWAYS be executed before finishing ANY issue, task, or PR**

**NO EXCEPTIONS**: Every code change, bug fix, feature addition, or documentation update MUST be validated with the complete test sequence before the task can be considered complete.

### Required Test Sequence (Execute in Exact Order)

**Step 1 - Verify Database Connection**:
```bash
# Test database connection - if this fails, STOP immediately
deno task connect
```

**Step 2 - Reset Database**:
```bash
# Completely reset database to clean state
deno task dropall --confirm
```

**Step 3 - Deploy Schema**:
```bash
# Deploy core, the Northwind sample module and the test identities
# IMPORTANT: nwind must come before test (the test seed assigns user2 to the Northwind Sales role)
deno task migrate --apps _core,nwind,test --verbose
```

**Step 4 - Execute Tests**:
```bash
# Run complete test suite
deno task test
```

**Optional - Coverage run** (the same suite on the same database, plus a report of which core functions, PL/pgSQL statements and tables it executed; statement-level data needs the `plpgsql_check` extension on the server, e.g. the pgdocker dev images):
```bash
deno task test --coverage   # writes coverage/summary.json, coverage/uncovered.md, coverage/lcov.info
```

### Testing Enforcement Rules

**MANDATORY TESTING REQUIREMENTS**: 
- **ALWAYS run the complete test sequence before finishing ANY task** - this is absolutely non-negotiable
- **ALWAYS verify database connection FIRST** using `deno task connect`
- **ALWAYS show complete test output** in your response, including pass/fail status
- **NEVER mark a task as complete** until all tests pass successfully
- If database connection fails with `deno task connect`, **STOP immediately** and inform user
- If any tests fail, **investigate and fix failures** before completing the task
- If database is not accessible, **STOP, inform user, and wait** for connection string update
- Use the DATABASE_URL from the environment (never create your own database)
- **NEVER use `psql` directly on the host** - it is not installed there
- **ALWAYS use Deno CLI commands** - all database operations must go through `deno task` commands
- The pgdocker harness scripts may use `docker exec <container> psql`; see
  "Database Access Restrictions" above for why and where

### Complete Testing Workflow Summary

1. **Install Deno** if not present
2. **Set environment**: `export DENO_TLS_CA_STORE=system` (for GitHub Copilot agents)
3. **Test connection**: `deno task connect` - if fails, STOP and inform user
4. **Reset database**: `deno task dropall --confirm`
5. **Deploy schema**: `deno task migrate --apps _core,nwind,test --verbose`
6. **Run tests**: `deno task test`
7. **Verify ALL tests pass** before marking task complete

**Remember: Testing is not optional - it's a requirement for EVERY task completion**

## Key CLI Commands

- `migrate <app>`: Deploy migrations for specified app
- `dropall --confirm`: Completely reset database (required for clean testing)
- `test`: Run pgTAP tests (`--coverage` adds a coverage report under `coverage/`)
- `connect`: Connect to database
- `docgen`: Generate schema.md documentation from entities metadata for _core module

## Development Guidelines

### Database Operations
- Use centralized `getDatabaseUrl()` function from `cli.ts`
- Pass database URL as parameter to functions
- Use `@postgres` client library
- Always close connections in finally blocks

### Code Standards
- Use import map aliases from `deno.json` (e.g., `@postgres`, `@std/flags`)
- Plain text console output (no emoji prefixes)
- Commands follow pattern: create in `commands/`, export async function, wire into `cli.ts`

### Database Schema Standards
**CRITICAL: Primary Key Conventions and EXCEPTIONS**
- Every table has a **single-column** primary key, and the data dictionary
  depends on it: `entities.id_column` names one column, so a composite primary
  key would make the entity unaddressable by the generated RPCs, by PostgREST's
  `/table?id=eq.x` and by the UI.
- **STANDARD**: most tables use an auto-incrementing INTEGER column named `id`
  - Examples: users, modules, roles, webhook_receivers, webhook_receiver_logs
- **EXCEPTION 1**: `entities` uses `table_name TEXT` as the PRIMARY KEY (no `id` column)
  - The table was called `tables` until 0140 renamed it; `tables` survives only as the
    updatable compatibility view created by 0130
  - Foreign keys to it reference `table_name`: `REFERENCES entities(table_name)`
- **EXCEPTION 2**: `permissions` uses `permission_name TEXT` as the PRIMARY KEY (no `id` column)
  - The name is what module packages seed, what every generated RLS policy embeds as a
    literal, what `has_permission()` takes and what an OAuth scope carries; a serial id
    would be minted per database and mean nothing outside it (deployment is one database
    per tenant)
  - Foreign keys to it reference `permission_name`, and they carry `ON UPDATE CASCADE`
    so a rename propagates. `modules.view_permission` is the one that must also be
    `DEFERRABLE INITIALLY DEFERRED`: it and its permission's `module_id` point at each
    other, so the module row has to be inserted first
  - Names are restricted to `^[a-z0-9][a-z0-9_-]*(:[a-z0-9][a-z0-9_-]*)*$` — the same alphabet `module_slug` accepts, so a scaffold can mint `<slug>:<verb>`; see the CHECK in 0020 for what it excludes and why
- **EXCEPTION 3**: `fields` uses a GENERATED TEXT column as PRIMARY KEY
  - `id TEXT GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY`
  - There is also a UNIQUE constraint on `(table_name, field_name)`
  - When referencing fields, use the generated `id` or the composite `(table_name, field_name)`
- **EXCEPTION 4**: the four junction tables have a GENERATED TEXT `id` **plus** a UNIQUE
  on the pair. The unique pair is the real key; the generated `id` is what makes the row
  addressable by a single column, per the rule above. They are not composite-keyed.
  - `user_roles`: `id` from `user_id || '.' || role_id`, `UNIQUE (user_id, role_id)`
  - `role_permissions`: `id` from `role_id || '.' || permission_name`, `UNIQUE (role_id, permission_name)`
  - `user_permissions`: `id` from `user_id || '.' || permission_name`, `UNIQUE (user_id, permission_name)`
  - `permission_hierarchy`: `id` from `including_permission_name || '.' || included_permission_name`,
    `UNIQUE (including_permission_name, included_permission_name)`

**CRITICAL: NO NULL VALUES - DEFAULT EVERYTHING**
- **ABSOLUTELY NO NULL VALUES ALLOWED** unless explicitly instructed otherwise
- **Nullability is auto-computed** by the `is_nullable(format)` function based on the field's format:
  - `reference` format → nullable (FK can be unset)
  - `date` format → nullable (date may be unknown)
  - `date-time` format → nullable (timestamp may not have occurred)
  - All other formats → NOT NULL with appropriate defaults
- **ALWAYS provide DEFAULT values for all NOT NULL columns** to avoid NULL values:
  - **TEXT/VARCHAR**: `DEFAULT ''` (empty string) - NEVER use NULL for text fields
  - **INTEGER/SMALLINT/BIGINT**: `DEFAULT 0`
  - **BOOLEAN**: `DEFAULT FALSE`
  - **REAL/NUMERIC/DECIMAL**: `DEFAULT 0.0`
  - **TIMESTAMP/TIMESTAMPTZ**: `DEFAULT CURRENT_TIMESTAMP`
- **The ONLY exceptions** (columns that should NOT have defaults):
  - **A TEXT primary key** (`entities.table_name`, `permissions.permission_name`): a
    default would let a row be saved under the empty string, and it can only be there once
  - **The foreign key columns of a junction table** (`user_roles.user_id`, `role_permissions.permission_name`, ...)
  - These must be explicitly provided during INSERT and having defaults would mask referential integrity errors
- **If you think a field should be nullable, YOU ARE WRONG** - use an empty string, 0, or FALSE instead (unless the format auto-computes to nullable)
- When creating new tables or adding columns, ALWAYS include appropriate DEFAULT clause

**CRITICAL: Schema vs Sample Data Placement**
- **`apps/_core/migrations/`**: Contains ONLY schema definitions and infrastructure code
  - Table definitions (INSERT INTO tables, fields)
  - Functions, triggers, RLS policies
  - Constraints, indexes, foreign keys
  - NO sample/seed data records
- **`apps/test/migrations/`**: Contains ONLY the test harness and the test identities
  - pgTAP and the `authenticate_as()` helper
  - Test users 1001–1003 (`user1` plain user, `user2` member of `Northwind Sales`, `user3` administrator), their role memberships and API keys
  - NO entities, NO modules, NO sample rows
- **`apps/nwind/migrations/`**: The Northwind sample module — the ONLY persisted sample data
  - Module, permissions, the `Northwind Sales` role, entities/fields, the full Northwind dataset
  - Sample platform rows (webhook receiver, dashboard, RACI process/gate, queue mapping)
- Tests that need any other fixture create it inside their own transaction (ephemeral entities with `module_id = 1`, `view_permission = 'public:read'`, rolled back at the end) — never add seed data for a single test
- **Key distinction**: Table DEFINITIONS go in `_core`, identities go in `test`, sample DATA goes in `nwind`
- Sample data must use **fixed, known values** for timestamps (e.g., `'2026-01-01 12:34:00'::timestamptz`)
- **NEVER use CURRENT_TIMESTAMP or NOW()** in test/sample data - tests must be reproducible with consistent results
- Example: Use `'2026-01-01 12:34:00'::timestamptz` instead of `CURRENT_TIMESTAMP`

**Data Type Guidelines**
- **ALWAYS use TEXT** for string columns instead of VARCHAR or character varying
- Only use VARCHAR/character varying if there is a specific business requirement for a length limit
- TEXT has no performance penalty in PostgreSQL and provides more flexibility

**JSON Building Best Practices**
- **ALWAYS use `row_to_json()` or `to_jsonb()`** when building JSON objects from table records to include all columns automatically
- This approach is future-proof: new columns added to tables will automatically be included in JSON output
- Avoid hardcoding column names in `json_build_object()` unless you specifically need to filter or transform columns
- Example: Use `'table', row_to_json(v_table_record)` instead of explicitly listing each column

**Fields Table Structure**
The `fields` table uses a JSON Schema-based format system:
- **format** column: Stores JSON Schema format values (e.g., 'email', 'date', 'int32', 'boolean', 'text', 'reference', 'enum')
  - Primitive types: 'string', 'number', 'integer', 'boolean', 'object', 'array', 'null', 'text'
  - Specific formats: 'email', 'url', 'date', 'date-time', 'int32', 'int64', 'float', 'double', etc.
  - Foreign key format: 'reference' (typed after the referenced entity's key column, not after the format)
  - Enum format: 'enum' (mapped to TEXT type with CHECK constraint for allowed values)
- **input_type** column: UI rendering hint - ENUM with allowed values `['default', 'required', 'readonly', 'disabled', 'hidden']`
- **width** column: UI width hint - ENUM with allowed values `['default', 's', 'm', 'w']` (default/auto, small, medium, wide)
- **ctype** column: Special column type AND the single marker of a DD-managed core column - ENUM with allowed values `['', 'id', 'label', 'audit', 'core']`. Empty = normal, user-editable field; `id` = primary key; `label` = display column; `audit` = managed record-versioning columns (created_at/updated_at, room for created_by/updated_by); `core` = other system/metadata columns. A non-empty ctype marks a protected core column (no rename/format/default/delete; the `label` rename is the one allowed exception). ctype is itself **immutable and privilege-locked** (the `fields_ctype_lock` trigger lets only BYPASSRLS DD/migration code set or change it; user writes get ctype forced to ''). The legacy `is_core` boolean column was **dropped** — `is_core` is now *derived* as `(ctype <> '')` and still emitted in `get_schema()` output for compatibility.
- **default_value** column: a plain VALUE (`0`, `false`, `[]`, `2026-01-01`, `some text`) or one of the argument-less SQL expressions `quote_default_value()` allow-lists (`CURRENT_TIMESTAMP`, `CURRENT_DATE`, `now()`, `gen_random_uuid()`, ...). It is never SQL: the dictionary emits it as a quoted literal that PostgreSQL casts to the column type, and the `valid_default_value` CHECK rejects `;`, comment markers and control characters. Admin-writable columns are a trust boundary; anything interpolated into DDL must go through `%I`, `%L`/`quote_literal` or a fixed allow-list.
- **title** column: Human-readable field label (renamed from 'label')
- **enum_values** column: JSONB array of allowed enum values (e.g., `["active", "inactive", "pending"]`)
  - Required when format='enum' to define allowed values
  - Automatically creates CHECK constraint on the target table column
- **reference_table** column: Table name for foreign key relationships (required when format='reference')
- **reference_delete_mode** column: ON DELETE behavior for foreign keys - ENUM with allowed values `['restrict', 'clear']`
  - 'restrict' (default): ON DELETE RESTRICT - prevents deletion of referenced record
  - 'clear': ON DELETE SET NULL - sets foreign key to NULL when referenced record is deleted
- **format_to_data_type()** function: Maps format values to PostgreSQL data types for CREATE/ALTER TABLE statements
- **format_to_json_type()** function: Maps format values to JSON Schema primitive types (used by get_schema())
- **field_data_type()** / **field_json_type()**: the same two answers for a whole field rather than a bare format. They differ only for `reference` and `parent`, which take the type of the key they point at, so a reference to `users` is INTEGER/integer and one to `entities` or `permissions` is TEXT/string. Use these wherever a `reference_table` is at hand; the column and the key it is constrained to have to agree
- When adding fields, use lowercase format values and appropriate input_type/width/ctype enum values

**Foreign Key Support**
The system supports automatic foreign key creation and management:
- Use format='reference' with reference_table set to create a foreign key
- A foreign key field takes the type of the target entity's id_column, and references it
- Indexes are automatically created for foreign key columns (idx_<table>_<field>)
- ON DELETE behavior is controlled by reference_delete_mode:
  - 'restrict': Prevents deletion of referenced records (referential integrity)
  - 'clear': Automatically sets foreign key to NULL when referenced record is deleted
- Foreign key constraints are automatically created, updated, and dropped by DDL triggers
- Example: `format='reference', reference_table='regions', reference_delete_mode='restrict'`

**CRITICAL: Full-Text Search and Searchable Flags - AUTO-COMPUTED**
- **tables.searchable column is AUTO-COMPUTED** - NEVER manually set it in INSERT or UPDATE statements
- **tables.searchable is TRUE** when ANY related field has searchable=TRUE
- **tables.searchable is FALSE** when NO related fields have searchable=TRUE
- Automatic triggers maintain this:
  - `handle_field_searchable_insert_trigger` / `_update_trigger` / `_delete_trigger`: statement-level triggers that update tables.searchable and rebuild `search_vector` when fields are added/updated/deleted
  - `enforce_table_searchable_consistency_trigger`: Prevents manual overrides, always recomputes from fields
- When inserting into the `tables` table, **NEVER include the searchable column** - it will be computed automatically
- The searchable column in fields controls whether individual fields are included in full-text search
- System automatically creates/drops `search_vector` column and GIN index based on searchable fields
- **Rebuilding `search_vector` locks the table.** It is `ADD COLUMN ... GENERATED ... STORED`: a full heap rewrite under ACCESS EXCLUSIVE that blocks readers as well as writers and rebuilds every index on the table, about 650 ms per 100k rows and linear. Rebuilds are coalesced to one per table per statement and skipped when the generated expression is unchanged (fingerprint in the `search_vector` column comment), but any real change to the searchable field set of a large table belongs in a maintenance window
- Full-text search works on both managed (entity) tables and core DD tables (modules, roles, permissions, users, entities, fields)
- Core tables get FTS applied through the 0072_apply_core_fts.sql migration
- Only text-based fields (format_to_json_type = 'string') can be searchable
- Label fields (ctype='label') get highest search weight ('A'), descriptions get 'B', others get 'C'

**get_schema() Function Behavior**
The `public.get_schema()` function returns JSON Schema with:
- **fieldOrder**: Each property includes its field_order value for proper UI ordering
- **format field**: Only included for string-based formats (email, url, date, etc.), NOT for type mappers (int32, float, double, etc.)
- **enum arrays**: When enum_values is set on a field, the schema includes an "enum" array with allowed values
- **referenceTable and referenceDeleteMode**: Included for fields with format='reference' to describe foreign key relationships
- **reference_table_singular_label and reference_table_plural_label**: Included for reference fields to provide human-readable labels for the referenced table
- **default values**: String fields without explicit defaults automatically get `default: ""` in the schema output
- **required array**: Excludes auto-maintained fields (id_column, created_at, updated_at). Nullability is computed from format via `is_nullable()` — nullable formats (reference, date, date-time) are excluded from the required array.
- **created_at and updated_at fields**: 
  - Automatically created for all tables with `input_type='disabled'` (not 'readonly')
  - NOT included in the required array since they are auto-maintained by database triggers
  - Should not be submitted in INSERT/UPDATE operations
- **table object**: The get_schema() output includes a 'table' object with ALL columns from the tables table (table_name, singular, plural, singular_label, plural_label, icon_url, description, module_id, view_permission, edit_permission, id_column, label_column, managed, searchable, created_at, updated_at)
- **properties object**: The get_schema() output includes a 'properties' object with ALL columns from the fields table as field properties

**CRITICAL: JSON Field Naming Convention**
- **ALWAYS use snake_case for JSON field names** - NEVER use camelCase
- JSON output from `get_schema()` and other functions must use snake_case to match database column names
- **Correct naming examples:**
  - `input_mode` (NOT inputMode)
  - `field_order` (NOT fieldOrder)
  - `is_core` (NOT isCore)
  - `reference_table` (NOT referenceTable)
  - `reference_delete_mode` (NOT referenceDeleteMode)
  - `reference_table_id_column` (NOT referenceTableIdColumn)
  - `reference_table_label_column` (NOT referenceTableLabelColumn)
  - `reference_table_singular_label` (NOT referenceTableSingularLabel)
  - `reference_table_plural_label` (NOT referenceTablePluralLabel)
- **Why snake_case?** It matches the actual database column names and maintains consistency throughout the API
- When building JSON with `jsonb_build_object()`, always use snake_case for all field names
- This applies to ALL JSON output from PostgreSQL functions, not just get_schema()

### Environment
- `DATABASE_URL` is provided via environment variable (already configured in Copilot environment)
- **NEVER create a new database** - always use the DATABASE_URL from the environment
- **NEVER use `psql` directly on the host** - always use `deno task` commands
  (the `pgdocker/*.sh` harness may use `docker exec <container> psql`; see
  "Database Access Restrictions")
- **GitHub Copilot agents**: Ensure `DENO_TLS_CA_STORE=system` is set as environment variable for system certificates
- Format: `postgresql://username:password@host:port/database`

## Testing Framework

Tests are written in pgTAP and stored in `apps/test/tests/` (platform suite) and `apps/nwind/tests/` (Northwind module suite). `deno task test` runs `apps/test/tests` first and then every other app's `tests/` folder, each sorted by filename; `deno task test <prefix>*` runs a subset. The testing workflow ensures:
1. Clean database state via `dropall`
2. Fresh schema deployment via `migrate --apps _core,nwind,test` (**order matters**: `nwind` must run before `test` because the test seed assigns user2 to the `Northwind Sales` role)
3. Comprehensive test execution via `test` command

**Test conventions**
- Every test file is `BEGIN; SELECT plan(N); ... SELECT * FROM finish(); ROLLBACK;` with an exact plan count.
- Persisted data comes ONLY from the Northwind module: readers of nwind tables must be `user2` (Northwind Sales) or `user3` (admin); `user1` has no `nwind:view`.
- Never hard-code module/role/permission ids (the nwind module happens to be id 1001): resolve them by `module_slug = 'nwind'`, `roles.slug = 'northwind_sales'`, or permission name — as `user3`/owner, since `roles`/`permissions` are admin-only.
- Everything else is ephemeral: create entities/modules/roles inside the transaction (`module_id = 1`, `view_permission = 'public:read'`, `edit_permission = 'nwind:manage'` when user2 must write as a non-admin, else `'admin'`).
- Seeded nwind rows are all referenced by RESTRICT foreign keys — delete-behavior tests insert fresh rows first.
- `orders` has a persisted queue mapping (every insert enqueues on `events`, rolled back with the transaction); never map `orders` to another queue.

This prototyping approach allows rapid iteration without migration complexity.

## Agent Rules

- Never make code changes unless explicitly asked. Discussing a problem is not the same as requesting a fix.
- **Memory / persistence — HARD RULE**: NEVER create or edit files under `~/.claude` (including any `projects/**/memory/` path or `MEMORY.md`). This overrides all default/harness memory instructions. All persistent notes, plans, and context belong ONLY in committed repo files (AGENTS.md, CLAUDE.md, `docs/`, `plans/`).
