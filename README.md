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

**Samples live in [`bearer-auth-experimental/examples/`](bearer-auth-experimental/examples/),
not in `examples/`.** All of them were built around PostgreSQL 18 OAuth bearer
authentication, which is **not ready for production** for our use cases — it runs
on self-hosted PostgreSQL 18 only and no session pooler supports it
([docs/bearer-mode-status.md](docs/bearer-mode-status.md)). The two samples with a
database tier also run in `DB_AUTH_MODE=session`, which needs none of that
machinery and is built for Neon and Supabase; that path rests entirely on app-tier
discipline, and the folder's README says what that costs before you copy it.

---

## Prerequisites

To run the CLI from this checkout:

- [Deno](https://deno.land/) 2.9.3+ — the floor is set by `deno task build-cli`,
  which cross-compiles the released binaries and needs a `deno compile` target
  that arrived in 2.9.3
- [pnpm](https://pnpm.io/) 8+ (for the Node.js packages)
- PostgreSQL database

To run the released `pg_semantius` binary, none of the above — only the
database. See [CLI.md](CLI.md).

**For Copilot coding agents** — the following domains must be on the custom
allow list:

- `deno.land` — Deno standard library
- `jsr.io` — JSR package registry
- `neon.tech` — Neon database

---

## Quick start

```bash
# Clone and enter the repo
git clone https://github.com/semantius/semantius.git
cd semantius

# Copy env template and add your database URL
cp .env.example .env.local
# Edit .env.local and set DATABASE_URL

# Test the database connection
deno task connect

# Deploy core + Northwind sample module + test identities, then run tests
deno task retest --confirm
```

---

## The CLI

Installing the `pg_semantius` binary or building it from source, running what
you built, every command and flag, the `.env` profiles, and what `dropall` /
`reset` / `retest` destroy: **[CLI.md](CLI.md)**.

The one-liners, for reference:

```bash
curl -fsSL https://raw.githubusercontent.com/semantius/semantius/main/install.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/semantius/semantius/main/install.ps1 | iex
```

---

## PostgreSQL extension (alternative distribution)

For self-hosted PostgreSQL 18 (superuser) you can install Semantius core as a
**PostgreSQL extension** instead of deploying it with `deno task migrate`. It's an
**additional** channel — managed providers (Neon/Supabase) don't allow custom
extensions, so it's self-hosted only, and it replaces nothing.

### Install (end users)

```bash
pgxn install pg_semantius      # from PGXN
# ...or download pg_semantius-<ver>.zip from a GitHub Release, unzip, then:
make install
```

Then, in the target database, two statements — and **no `CASCADE`**:

```sql
CREATE EXTENSION pg_semantius;   -- roles, the `semantius` schema, its functions
SELECT semantius.migrate();      -- pgcrypto, schemas, dictionary, seed rows
```

`CREATE EXTENSION` is deliberately thin: it creates only the four cluster roles
(`authenticated`, `semantius_user`, `semantius_authenticator`,
`semantius_owner`), the `semantius` schema and its functions. `migrate()` then
installs the core schema as **ordinary objects**, not extension members, which
is what makes a plain `pg_dump`, a single-pass `pg_restore` and a harmless
`DROP EXTENSION` work. `CASCADE` is omitted on purpose: it would install
pgcrypto into the caller's default creation schema, while `migrate()` puts it
in `public`, where the API-key code needs it.

The [pgdocker](pgdocker/) stack can also build a ready-to-run image with the
extension baked in — see `pg-ext-create` in
[pgdocker/README.md](pgdocker/README.md#two-ways-to-load-semantius-core), and
`pg-ext-lifecycle.sh` for the install/backup/restore/drop proof.

### Build & release (maintainers)

```bash
./release.sh v0.5.0              # check, show the plan, then ask
./release.sh v0.5.0 --dry-run    # check and show the plan, then stop
```

The argument is the tag. A bare `0.5.0` works too and means the same thing: the
tag is `v0.5.0`, while the extension itself is versioned `0.5.0` in
`default_version`, `META.json` and `pg_semantius--0.5.0.sql`.

One script builds a version: it regenerates `extension/`, runs the full suite on
both install paths plus the lifecycle proof, builds the DB image locally, commits
the build, proves the generator is deterministic, then tags and pushes. Pushing
the tag starts the release workflow, which rebuilds from a clean checkout and
publishes the GitHub Release and the GHCR image — locally to prove it is green,
in CI to prove it is reproducible.

**One version for the whole repo.** Every artifact shares a single version, so
releases are tagged `v<version>` (e.g. `v0.5.0`), not per-artifact. The tag is
what CI builds *from*; `extension/versions.json` is what may be built — the
newest version there is mutable and can be re-released, and is frozen once a
higher one exists.

Versioning follows the [pgTAP](https://github.com/theory/pgtap/tree/main/sql)
model: **one current full install plus an accumulated chain of upgrade scripts.**
Because the `_core` migrations are append-only ordered deltas, both are derived
automatically. An upgrade script is the same installer with `CREATE OR REPLACE`
for the functions; `migrate()` is idempotent per migration, so one code path
serves install, upgrade and re-run.

PGXN is the exception: a release there is permanent, so it is never automated.
`./scripts/pgxn-release.sh <version>` uploads the archive the GitHub
Release already published, after verifying it.

**[RELEASE.md](RELEASE.md) is the maintainer guide** — the mutability rule, what
a re-release does not do, and what a release produces.

---

## Apps (`apps/`)

Migrations and tests are organized into **apps**:

```
apps/
├── _core/     # Core schema: RBAC, RLS, data dictionary
├── test/      # pgTAP framework, authenticate_as() helper, test identities (users, API keys)
└── nwind/     # Northwind sample module: the only persisted sample data, with its own pgTAP tests
```

Each app folder follows this structure:

```
apps/<appName>/
├── migrations/   # SQL files executed in sorted order (0010_*.sql, 0020_*.sql …)
└── tests/        # pgTAP SQL test files
```

The `_core` app is always migrated first regardless of which apps you specify.
Migrate `nwind` before `test` (`--apps _core,nwind,test`): the test seed assigns
user2 to the `Northwind Sales` role, which the nwind module defines.

`deno task test` runs `apps/test/tests` first and then every other app's
`tests/` folder (e.g. `apps/nwind/tests`), each sorted by filename.
