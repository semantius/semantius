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

The project includes predefined tasks in `deno.json`:

```bash
# Start the CLI
deno task start

# Initialize project
deno task init

# Build project
deno task build

# Test database connection
deno task test

# Run linter
deno task lint

# Format code
deno task fmt

# Type check
deno task check
```

### Command Options

- `--verbose`: Enable verbose output for commands
- `--config <FILE>`: Specify a custom config file path
- `--output <DIR>`: Specify output directory for build command




### Configuration

Copy `.env.example` file to `.env.local` and add your PostgreSQL connection string:

```bash
DATABASE_URL='postgresql://username:password@host:port/database?sslmode=require'
```

Verify the connection with 

```bash
deno task test
```

