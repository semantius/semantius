# The Semantius CLI (`pg_semantius`)

Deploys the schema, runs the pgTAP suite, and generates the PostgreSQL
extension. It ships two ways, and they are the same program:

- `deno task <command>` from a checkout of this repository
- `pg_semantius <command>`, a single self-contained executable

Every example below works either way.

- Overview and quick start: [README.md](README.md)
- Cutting a release: [RELEASE.md](RELEASE.md)
- Local PostgreSQL to point it at: [pgdocker/README.md](pgdocker/README.md)

---

## Install the binary

The executable is attached to every
[release](https://github.com/semantius/semantius/releases).

```bash
curl -fsSL https://raw.githubusercontent.com/semantius/semantius/main/install.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/semantius/semantius/main/install.ps1 | iex
```

| Asset | Platform |
|---|---|
| `pg_semantius-linux-x64` | Linux, x86-64 |
| `pg_semantius-linux-arm64` | Linux, ARM64 |
| `pg_semantius-darwin-arm64` | macOS, Apple Silicon |
| `pg_semantius-windows-x64.exe` | Windows, x64 |
| `pg_semantius-windows-arm64.exe` | Windows, ARM64 |
| `checksums.txt` | SHA-256 of all five |

There is no macOS x64 build; on an Intel Mac, run the CLI from a checkout.

The binary carries the `_core`, `nwind` and `test` SQL of the release it came
from, so `pg_semantius migrate --apps _core` works in an empty directory. If
the working directory does have an `apps/<name>`, that copy is used instead of
the embedded one, per app, and the CLI says so on the line it prints. So a
project with its own `apps/myapp` still gets `_core` from the binary.

Two commands have database-side prerequisites, which are not dependencies of
the binary: `test` needs pgTAP in the target database (`pg_semantius migrate
--apps test` installs it), and `--coverage` needs `plpgsql_check` on the server
for statement-level data (without it, function-level data is still reported).
Beyond that the binary needs nothing at all — no Deno, no `node_modules`, no
network other than the PostgreSQL connection.

`init`, `lint` and `format` are the exceptions: they scaffold or lint a source
tree, so they exist only when the CLI runs from a checkout and the binary does
not offer them.

### Building it yourself

```bash
deno task build-cli        # this platform, into dist/
deno task build-cli:all    # all five published targets
```

The file is named after the platform it was built for, so `dist/` holds
`pg_semantius-windows-x64.exe` on Windows, `pg_semantius-linux-x64` on Linux,
and so on. `deno task build-cli --help` lists every name.

### Running what you just built

`dist/` is not on your PATH, so a fresh build is run by path. From the
repository root:

```bash
./dist/pg_semantius-linux-x64 --version          # Linux / macOS
```

```powershell
.\dist\pg_semantius-windows-x64.exe --version    # Windows
```

From anywhere else, give the full path — `C:\dev\semantius\dist\pg_semantius-windows-x64.exe`,
`~/src/semantius/dist/pg_semantius-linux-x64`. Commands that read a `.env.<name>`
profile still resolve it against the *current* directory, so run those from the
repository root or pass `--database-url` instead.

To type `pg_semantius` instead, copy it where the installers put it — the same
destination, so a later `install.sh` / `install.ps1` replaces it cleanly:

```bash
mkdir -p ~/.local/bin
cp dist/pg_semantius-linux-x64 ~/.local/bin/pg_semantius
```

```powershell
Copy-Item dist\pg_semantius-windows-x64.exe "$env:LOCALAPPDATA\Programs\Semantius\pg_semantius.exe"
```

On Windows that directory is created and added to PATH by `install.ps1`; if you
have never run it, create the directory and add it to your PATH once. On
Linux/macOS, `~/.local/bin` must be on your PATH.

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
| `--coverage` | Measure which functions/statements/tables the pgTAP suite executes (for `test` and `retest`); writes `coverage/` |
| `--coverage-min <PCT>` | Exit 1 when function coverage is below `PCT` percent (implies `--coverage`) |

### Commands

| Command | Description |
|---------|-------------|
| `init` | Initialize a new project (checkout only) |
| `connect` | Test the database connection |
| `test` | Run pgTAP tests |
| `lint` | Run Deno linter (checkout only) |
| `format` / `fmt` | Format code (checkout only) |
| `migrate` | Execute SQL migrations for specified apps |
| `extension` | Generate the Semantius core PostgreSQL extension into `extension/` |
| `dropall` | **DESTRUCTIVE** — drop ALL objects in public schema |
| `reset` | **DESTRUCTIVE** — dropall + migrate `_core` only (no sample data, no tests) |
| `retest` | **DESTRUCTIVE** — dropall + migrate `_core,nwind,test` + run tests |
| `docgen` | Generate `schema.md` from entity metadata |
| `bundle-sql` | Bundle SQL files for Node.js/serverless deployment (`deno task` only) |

`deno task build-cli` and `deno task build-cli:all` compile the `pg_semantius`
binary; they are build tooling, not CLI commands. There is deliberately no
task called plain `build`: this repository produces three artifacts, and each
one is named — `build-cli` for the binary, `extension <ver>` for the
PostgreSQL extension, `docker-postgres/build.sh` for the database image.

### Examples

```bash
# Test connection
deno task connect --verbose

# Supply the database URL directly (overrides .env)
deno task connect --database-url "postgresql://user:pass@host:5432/db"

# Run migrations (nwind before test: the test seed assigns user2 to the Northwind Sales role)
deno task migrate --apps _core,nwind,test --verbose
deno task migrate --apps nwind --database-url "postgresql://..."

# Generate a migration SQL script without executing
deno task migrate --apps _core --script

# Generate the PostgreSQL extension (control + versioned SQL) into ./extension/
# For a release use ./release.sh instead - it also tests, commits and tags.
deno task extension 0.5.0

# Drop all database objects (requires confirmation)
deno task dropall --confirm

# Full cycle: drop all + migrate _core,nwind,test + run tests
deno task retest --confirm
deno task retest --confirm --failfast

# Reset to a bare _core schema (no sample data, no tests)
deno task reset --confirm

# Use a different environment file
deno task connect --env staging
deno task migrate --apps nwind --env staging

# Run pgTAP tests (apps/test/tests first, then every other apps/*/tests, sorted by filename)
deno task test
deno task test --tap   # plain TAP output
deno task test 0160*   # only files whose name matches the prefix

# Same suite with coverage: which core functions, PL/pgSQL statements and tables
# the tests execute. Statement-level data needs the plpgsql_check extension on
# the server (the pgdocker dev images); without it only function-level data is
# reported. Reports: coverage/summary.json, coverage/uncovered.md, coverage/lcov.info
deno task test --coverage
deno task test --coverage --coverage-min 80   # exit 1 below 80% function coverage
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
| `--env pgdocker-cli` | `.env.pgdocker-cli` |
| `--env pgdocker-ext` | `.env.pgdocker-ext` |
| `--env test` | `.env.test` |
| `--env staging` | `.env.staging` |

The `--database-url` flag takes the highest priority and overrides both the
`.env` file and the `DATABASE_URL` environment variable.

### Local pgdocker database

There are two ready-made profiles for the local [pgdocker](pgdocker/) stacks,
both connecting as the `postgres` DBA:

- `.env.pgdocker-cli` — the plain CLI-testing container on `localhost:5432`.
- `.env.pgdocker-ext` — the extension container on `localhost:5433`.

Edit them to match your `pgdocker/.env` (password, port, database), then either:

- use one per-command: `deno task migrate --apps _core --env pgdocker-cli`, or
- make one the default: `cp .env.pgdocker-cli .env.local`.

---

## Safety warnings

### `dropall`

Permanently deletes **ALL** objects in the public schema (tables, views,
functions, sequences, types, and user-owned schemas). **Cannot be undone.**

```bash
deno task dropall --confirm
```

### `reset`

Combines `dropall --confirm` → `migrate --apps _core` (no sample data, no
tests). Requires `--confirm`:

```bash
deno task reset --confirm
```

### `retest`

Combines `dropall --confirm` → `migrate --apps nwind,test` (`_core` is
prepended automatically) → `test`. Requires `--confirm`:

```bash
deno task retest --confirm
```
