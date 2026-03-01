# Semantius Core CLI

A powerful command-line interface built with Deno for the Semantius Core project.

## Prerequisites

- [Deno](https://deno.land/) 1.37+ installed
- Copilot coding agent needs the following domains to be the the custom allow list:
  - `deno.land` - Deno standard library and packages
  - `jsr.io` - JSR package registry
  - `neon.tech` - Neon database
  - `supabase.co` - Supabase database (fails currently, cloud tests only work with neon)
- PostgreSQL database (connection provided via DATABASE_URL environment variable)

## Installation

Clone the repository and navigate to the project directory:

```bash
git clone <repository-url>
cd semantius-core
```


## Usage

```bash
deno task [OPTIONS] [COMMAND]
```

### Options

- `-h, --help`: Show help message
- `--version`: Show version information
- `-v, --verbose`: Enable verbose output
- `--config <FILE>`: Specify config file path
- `--output <DIR>`: Specify output directory
- `--apps <APPS>`: Comma-separated list of app names (for migrate command)
- `--script`: Generate migrate.sql file instead of executing (for migrate command)
- `--confirm`: Skip confirmation prompt (for dropall and reset commands)
- `--env <ENV>`: Environment name to load (default: `local`, loads `.env.<ENV>` file)

### Commands

- `init`: Initialize a new project
- `build`: Build the project
- `test`: Run pgTAP tests
- `lint`: Run linter
- `format`: Format code
- `connect`: Test database connection
- `migrate`: Process and validate app folders (requires --apps parameter)
- `dropall`: ⚠️ **DANGER**: Drop ALL database objects in public schema (DESTRUCTIVE!)
- `reset`: ⚠️ **DANGER**: Drop all, migrate `--apps test`, and run tests (requires `--confirm`)
- `docgen`: Generate schema.md documentation from entities metadata

### Examples

```bash
# Show help
deno task --help

# Initialize project
deno task init

# Build project with custom output directory
deno task build --output ./dist

# Test database connection with verbose output
deno task connect --verbose

# Run migration on specific apps
deno task migrate --apps app1,app2,app3 --verbose
deno task migrate --apps nwind,_ddtest

# Generate migration script without executing
deno task migrate --apps _core --script

# Drop all database objects (DANGEROUS - use with caution!)
deno task dropall --verbose

# Reset database: drop all, migrate test apps, run tests (DANGEROUS!)
deno task reset --confirm
deno task reset --confirm --verbose

# Use a different environment file (e.g. .env.test instead of .env.local)
deno task connect --env test
deno task migrate --apps nwind --env staging

# Run test directly with deno
deno run --allow-read --allow-write --allow-env --allow-net cli.ts test
```

## ⚠️ IMPORTANT SAFETY WARNING: dropall Command

The `dropall` command is a **DESTRUCTIVE** operation that will permanently delete ALL database objects in the public schema, including:

- All tables and their data
- All views  
- All functions and procedures
- All sequences
- All custom types
- All other database objects

**This operation CANNOT be undone!**

### Safety Features

- Requires explicit confirmation by typing 'Y' when prompted
- Shows detailed warning before execution
- Lists all objects being dropped with console.log output
- Only affects the public schema (leaves system schemas intact)

### Usage

```bash
# Run dropall command (will prompt for confirmation)
deno task dropall

# Or with verbose output
deno task dropall --verbose
```

**Use this command only in development environments or when you specifically need to reset your database schema completely.**

## ⚠️ IMPORTANT SAFETY WARNING: reset Command

The `reset` command is a **DESTRUCTIVE** operation that combines three steps:

1. `dropall --confirm` — permanently deletes ALL database objects
2. `migrate --apps test` — re-deploys the schema for the `test` app
3. `test` — runs the full pgTAP test suite

**The `--confirm` flag is required.** Running `deno task reset` without `--confirm` will print an error and exit immediately.

### Usage

```bash
# Reset (requires --confirm)
deno task reset --confirm

# Reset with verbose output
deno task reset --confirm --verbose
```

## Environment Files (`--env` option)

By default all commands load environment variables from `.env.local`. Use the `--env` flag to load a different environment file:

| Flag | File loaded |
|------|------------|
| *(none)* | `.env.local` |
| `--env test` | `.env.test` |
| `--env staging` | `.env.staging` |

### Examples

```bash
# Use .env.test instead of .env.local
deno task connect --env test
deno task migrate --apps nwind --env test
deno task reset --confirm --env test
```




### Configuration

**For local development:**

Copy `.env.example` file to `.env.local` and add your PostgreSQL connection string:

```bash
DATABASE_URL='postgresql://username:password@host:port/database?sslmode=require'
```

**For CI/CD and automated environments:**

The `DATABASE_URL` environment variable should be set in your environment. The CLI will automatically use it.

**Database Connection Requirements:**

For Supabase databases (e.g., `postgresql://postgres:password@db.xxxxx.supabase.co:5432/postgres`):
- Network access to `*.supabase.co` domain on port 5432
- SSL/TLS connection support

Verify the connection with:

```bash
deno task test
```

