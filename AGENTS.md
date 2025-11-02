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

**CRITICAL**: Always execute these commands in order for testing:

1. **Reset database**: `deno task dropall --confirm`
2. **Setup database**: `deno task migrate test --verbose`
3. **Run tests**: `deno task test`

**MANDATORY TESTING REQUIREMENTS**: 
- **ALWAYS run tests before completing any task or PR** - this is non-negotiable
- Tests MUST be executed for every change to validate functionality
- Show the complete test output in your response, including pass/fail status
- If tests fail, investigate and fix the failures before marking the task complete
- If database is not accessible, document the limitation and explain what tests should verify
- Use the DATABASE_URL from the environment (never create your own database)
- Never use `psql` directly - always use the Deno CLI commands

**Testing Workflow Summary**:
1. Install Deno if not present
2. Set `export DENO_TLS_CA_STORE=system`
3. Run `deno task dropall --confirm` to reset database
4. Run `deno task migrate test --verbose` to deploy schema
5. Run `deno task test` to execute all tests
6. Verify all tests pass before completing the task

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
