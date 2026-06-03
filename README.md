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
| `--env test` | `.env.test` |
| `--env staging` | `.env.staging` |

The `--database-url` flag takes the highest priority and overrides both the
`.env` file and the `DATABASE_URL` environment variable.

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
