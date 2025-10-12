# Semantius Core CLI

A powerful command-line interface built with Deno for the Semantius Core project.

## Prerequisites

- [Deno](https://deno.land/) 1.37+ installed

## Installation

Clone the repository and navigate to the project directory:

```bash
git clone <repository-url>
cd semantius-core
```

## Usage

```bash
deno task start [OPTIONS] [COMMAND]
```

### Options

- `-h, --help`: Show help message
- `--version`: Show version information
- `-v, --verbose`: Enable verbose output
- `--config <FILE>`: Specify config file path
- `--output <DIR>`: Specify output directory
- `--apps <APPS>`: Comma-separated list of app names (for migrate command)

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
deno task start --help

# Initialize project
deno task start init

# Build project with custom output directory
deno task start build --output ./dist

# Test database connection with verbose output
deno task start test --verbose

# Run migration on specific apps
deno task start migrate --apps app1,app2,app3 --verbose
deno task start migrate --apps nwind,_ddtest

# Drop all database objects (DANGEROUS - use with caution!)
deno task start dropall --verbose

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
deno task start dropall --verbose
```

**Use this command only in development environments or when you specifically need to reset your database schema completely.**




### Configuration

Copy `.env.example` file to `.env.local` and add your PostgreSQL connection string:

```bash
DATABASE_URL='postgresql://username:password@host:port/database?sslmode=require'
```

Verify the connection with 

```bash
deno task test
```

