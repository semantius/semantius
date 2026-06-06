# Semantius Core

A database-first backend framework with permissions and business logic enforced
in PostgreSQL via Row Level Security (RLS) and custom RBAC.

## Repository structure

This is a **pnpm monorepo**. The two main packages are:

```
packages/
├── core/  @semantius/core — shared migration logic (Deno + Node.js)
└── cli/   @semantius/cli  — Deno CLI for local development
```

Each Deno package (`core`, `cli`) has its own `deno.json` — this is the standard
Deno workspace pattern and is equivalent to how each npm package in a pnpm
workspace has its own `package.json`.

---

## Prerequisites

- [Deno](https://deno.land/) 1.37+
- [pnpm](https://pnpm.io/) 8+ (for the Node.js packages)
- PostgreSQL database

**For Copilot coding agents** — the following domains must be on the custom
allow list:

- `deno.land` — Deno standard library
- `jsr.io` — JSR package registry
- `neon.tech` — Neon database

---

## Quick start

```bash
# Clone and enter the repo
git clone <repository-url>
cd semantius-core

# Copy env template and add your database URL
cp .env.example .env.local
# Edit .env.local and set DATABASE_URL

# Test the database connection
deno task connect

# Deploy schema + test data, then run tests
deno task reset --confirm
```

---

## CLI usage (`packages/cli`)

All Deno tasks are defined in the root `deno.json` and run `packages/cli/cli.ts`.

```bash
deno task [COMMAND] [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help message |
| `--version` | Show version information |
| `-v, --verbose` | Enable verbose output |
| `--apps <APPS>` | Comma-separated app names (for `migrate`) |
| `--confirm` | Skip confirmation prompt (for `dropall`, `reset`) |
| `--script` | Generate SQL file instead of executing |
| `--env <ENV>` | Load `.env.<ENV>` instead of `.env.local` |
| `--database-url <URL>` | Database URL — overrides `DATABASE_URL` env var and `.env` file |

### Commands

| Command | Description |
|---------|-------------|
| `init` | Initialise a new project |
| `build` | Compile the CLI to a native binary |
| `connect` | Test the database connection |
| `test` | Run pgTAP tests |
| `lint` | Run Deno linter |
| `format` / `fmt` | Format code |
| `migrate` | Execute SQL migrations for specified apps |
| `extension` | Generate the Semantius core PostgreSQL extension into `extension/` |
| `dropall` | **DESTRUCTIVE** — drop ALL objects in public schema |
| `reset` | **DESTRUCTIVE** — dropall + migrate test + run tests |
| `docgen` | Generate `schema.md` from entity metadata |
| `bundle-sql` | Bundle SQL files for Node.js/serverless deployment |

### Examples

```bash
# Test connection
deno task connect --verbose

# Supply the database URL directly (overrides .env)
deno task connect --database-url "postgresql://user:pass@host:5432/db"

# Run migrations
deno task migrate --apps _core,nwind --verbose
deno task migrate --apps nwind --database-url "postgresql://..."

# Generate a migration SQL script without executing
deno task migrate --apps _core --script

# Generate the PostgreSQL extension (control + versioned SQL) into ./extension/
deno task extension
deno task extension 0.2.0    # explicit version

# Drop all database objects (requires confirmation)
deno task dropall --confirm

# Full reset: drop all + re-migrate + run tests
deno task reset --confirm
deno task reset --confirm --verbose

# Use a different environment file
deno task connect --env staging
deno task migrate --apps nwind --env staging

# Run pgTAP tests
deno task test
deno task test --tap   # plain TAP output
```

---

## Environment configuration

Copy `.env.example` to `.env.local` and set your connection string:

```bash
DATABASE_URL='postgresql://username:password@host:port/database?sslmode=require'
```

| Flag | File loaded |
|------|------------|
| *(none)* | `.env.local` |
| `--env pgdocker` | `.env.pgdocker` |
| `--env test` | `.env.test` |
| `--env staging` | `.env.staging` |

The `--database-url` flag takes the highest priority and overrides both the
`.env` file and the `DATABASE_URL` environment variable.

### Local pgdocker database

`.env.pgdocker` is a ready-made profile for the local [pgdocker](pgdocker/)
container — it connects as the `postgres` DBA on `localhost:5432`. Edit it to
match your `pgdocker/.env` (password, port, database), then either:

- use it per-command: `deno task migrate --apps _core --env pgdocker`, or
- make it the default: `cp .env.pgdocker .env.local`.

---

## PostgreSQL extension (alternative distribution)

For self-hosted PostgreSQL 18 (superuser) you can install Semantius core as a
**PostgreSQL extension** instead of deploying it with `deno task migrate`. It's an
**additional** channel — managed providers (Neon/Supabase) don't allow custom
extensions, so it's self-hosted only, and it replaces nothing.

### Install (end users)

```bash
pgxn install semantius                 # from PGXN
# ...or download semantius-<ver>.zip from a GitHub Release, unzip, then:
make install
```

Then, in the target database: `CREATE EXTENSION semantius CASCADE;` — it creates
its own `authenticated`/`semantius_user` roles and pulls in `pgcrypto`, so there's
nothing to set up first. The [pgdocker](pgdocker/) stack can also build a
ready-to-run image with the extension baked in — see `pg-ext-create` in
[pgdocker/README.md](pgdocker/README.md#two-ways-to-load-semantius-core).

### Build & release (maintainers)

**One version for the whole repo.** Every artifact in this repo (the extension, and
later the CLI) shares a single version, so releases are tagged with an unprefixed
`v<version>` (e.g. `v0.1.0`) — not a per-artifact prefix. The tag is the source of
truth: the release workflow derives the version from it.

Versioning follows the [pgTAP](https://github.com/theory/pgtap/tree/main/sql)
model: **one current full install plus an accumulated chain of upgrade scripts.**
Because the `_core` migrations are append-only ordered deltas, both are derived
automatically.

```bash
deno task extension              # rebuild the current version (from the CLI package)
deno task extension 0.2.0        # cut a new version
```

`deno task extension 0.2.0` (with `0.1.0` already released):
- writes the current full install `semantius--0.2.0.sql` and **removes the prior
  `semantius--0.1.0.sql`** (keep one full install, like pgTAP);
- writes the upgrade script `semantius--0.1.0--0.2.0.sql` — just the migrations
  added since 0.1.0 — so `ALTER EXTENSION semantius UPDATE` walks the chain;
- bumps `default_version`, records the version in `versions.json`, and refreshes
  `META.json`/`Makefile`/README.

Once a version is released its migrations are **frozen** — make later changes in
*new* migration files. The generator hashes each migration in `versions.json` and
**warns** if a released one was edited (that change can't land in an upgrade script).

**Release flow:** generate → test → commit `extension/` (incl. `versions.json`) →
tag → push. The [Release extension](.github/workflows/extension-release.yml) workflow
fires on the `v*` tag, regenerates at the tag's version, zips the full install **+ the
whole upgrade chain** into `semantius-<ver>.zip`, and attaches it to a GitHub Release:

```bash
deno task extension 0.2.0                              # 1. regenerate at the new version
deno task reset --confirm                              # 2. test (dropall + migrate + pgTAP)
git add extension && git commit -m "release v0.2.0"    # 3. commit the generated files
git tag v0.2.0 && git push origin main v0.2.0          # 4. tag + push → workflow publishes
```

If a version is **already generated and committed** but never tagged (as `0.1.0`
was), just publish it — no regenerate, no commit needed, only the tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

That same `semantius-<ver>.zip` is the PGXN archive — publish it (needs a pgxn.org
account) with `pgxn release semantius-0.2.0.zip` (or upload at manager.pgxn.org).
Details in [extension/README.md](extension/README.md).

---

## Apps (`apps/`)

Migrations and tests are organised into **apps**:

```
apps/
├── _core/     # Core schema: RBAC, RLS, data dictionary
├── test/      # pgTAP testing infrastructure + seed data
└── nwind/     # Example app (Northwind)
```

Each app folder follows this structure:

```
apps/<appName>/
├── migrations/   # SQL files executed in sorted order (0010_*.sql, 0020_*.sql …)
└── tests/        # pgTAP SQL test files
```

The `_core` app is always migrated first regardless of which apps you specify.

---

## Safety warnings

### `dropall`

Permanently deletes **ALL** objects in the public schema (tables, views,
functions, sequences, types, and user-owned schemas). **Cannot be undone.**

```bash
deno task dropall --confirm
```

### `reset`

Combines `dropall --confirm` → `migrate --apps test` → `test`. Requires
`--confirm`:

```bash
deno task reset --confirm
```
