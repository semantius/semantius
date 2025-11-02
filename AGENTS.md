# AGENTS.md - AI Agent Documentation

This document provides essential information for AI agents working with the Semantius Core project.

## Project Overview

**Semantius Core** is a database-first backend where permissions and business logic are enforced in PostgreSQL using Row Level Security (RLS) and custom RBAC.

- **CLI**: Deno with TypeScript
- **CLI Purpose**: Deploy database schema, functions, and run tests
- **Database**: PostgreSQL with custom RBAC and RLS
- **Status**: Prototyping mode (always start with empty database, no migration compatibility needed)

## Prerequisites

### Deno Installation

**CRITICAL**: Deno must be installed before running any commands.

Install Deno (version 1.37+):
```bash
cd /tmp
wget -q https://github.com/denoland/deno/releases/download/v1.45.5/deno-x86_64-unknown-linux-gnu.zip
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

## Core Architecture

### Database-First Design
- All business logic implemented in PostgreSQL functions
- Security enforced through RLS policies and custom RBAC
- Infrastructure defined in `apps/_core/` folder
- Automated testing using pgTAP framework

### Project Structure
```
apps/
├── _core/          # Core database infrastructure
│   └── migrations/ # Schema, RBAC, RLS setup
├── test/           # pgTAP testing framework
│   ├── migrations/ # Test infrastructure setup
│   └── tests/      # Actual test files
└── nwind/          # Example app (Northwind)
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
# Deploy all migrations and test infrastructure
deno task migrate test --verbose
```

**Step 4 - Execute Tests**:
```bash
# Run complete test suite
deno task test
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
- Never use `psql` directly - always use the Deno CLI commands

### Complete Testing Workflow Summary

1. **Install Deno** if not present
2. **Set environment**: `export DENO_TLS_CA_STORE=system` (for GitHub Copilot agents)
3. **Test connection**: `deno task connect` - if fails, STOP and inform user
4. **Reset database**: `deno task dropall --confirm`
5. **Deploy schema**: `deno task migrate test --verbose`
6. **Run tests**: `deno task test`
7. **Verify ALL tests pass** before marking task complete

**Remember: Testing is not optional - it's a requirement for EVERY task completion**

## Key CLI Commands

- `migrate <app>`: Deploy migrations for specified app
- `dropall --confirm`: Completely reset database (required for clean testing)
- `test`: Run pgTAP tests
- `connect`: Connect to database

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

### Environment
- `DATABASE_URL` is provided via environment variable (already configured in Copilot environment)
- **NEVER create a new database** - always use the DATABASE_URL from the environment
- **NEVER use `psql` directly** - always use `deno task` commands
- **GitHub Copilot agents**: Ensure `DENO_TLS_CA_STORE=system` is set as environment variable for system certificates
- Format: `postgresql://username:password@host:port/database`

## Testing Framework

Tests are written in pgTAP and stored in `apps/test/tests/`. The testing workflow ensures:
1. Clean database state via `dropall`
2. Fresh schema deployment via `migrate test`
3. Comprehensive test execution via `test` command

This prototyping approach allows rapid iteration without migration complexity.
