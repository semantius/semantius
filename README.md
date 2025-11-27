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

### Commands

- `init`: Initialize a new project
- `build`: Build the project
- `test`: Test database connection
- `lint`: Run linter
- `format`: Format code
- `migrate`: Process and validate app folders (requires --apps parameter)
- `dropall`: ⚠️ **DANGER**: Drop ALL database objects in public schema (DESTRUCTIVE!)

### Examples

```bash
# Show help
deno task --help

# Initialize project
deno task init

# Build project with custom output directory
deno task build --output ./dist

# Test database connection with verbose output
deno task test --verbose

# Run migration on specific apps
deno task migrate --apps app1,app2,app3 --verbose
deno task migrate --apps nwind,_ddtest

# Generate migration script without executing
deno task migrate --apps _core --script

# Drop all database objects (DANGEROUS - use with caution!)
deno task dropall --verbose

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

