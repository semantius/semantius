# Semantius Core - GitHub Copilot Instructions

## Project Overview

**Semantius Core** is a database-first backend system where all business logic and security are implemented in PostgreSQL using Row Level Security (RLS) and custom Role-Based Access Control (RBAC).

## Key Architecture Principles

### Database-First Design
- All business logic is implemented as PostgreSQL functions
- Security is enforced through RLS policies and custom RBAC
- The CLI tool (Deno + TypeScript) is only for deployment and testing
- Infrastructure is defined in the `apps/_core/` folder
- Testing uses the pgTAP framework

### Project Structure
```
apps/
├── _core/          # Core database infrastructure
│   └── migrations/ # Schema, RBAC, RLS setup
├── test/           # pgTAP testing framework
│   ├── migrations/ # Test infrastructure setup
│   └── tests/      # Actual test files
└── nwind/          # Example app (Northwind database)
```

## Development Workflow

**CRITICAL**: Always execute these commands in this exact order for testing:

1. **Reset database**: `deno task dropall --confirm`
2. **Setup database**: `deno task migrate test --verbose`
3. **Run tests**: `deno task test`

**AGENT RESPONSIBILITY**: The agent MUST execute this full cycle after making any changes to verify nothing is broken. This is a throwaway test database - it's safe and required to run these operations.

## Code Standards

### Database Development
- Write SQL functions in PostgreSQL (not application code)
- Use RLS policies for security enforcement
- Implement RBAC through custom functions
- Store migrations in numbered files (e.g., `0010_`, `0020_`)

### CLI Development
- Use Deno with TypeScript
- Import map aliases from `deno.json` (e.g., `@postgres`, `@std/flags`)
- Use centralized `getDatabaseUrl()` function from `cli.ts`
- Always close database connections in finally blocks
- Plain text console output (no emoji prefixes)

### Testing
- Write tests in pgTAP format
- Store tests in `apps/test/tests/`
- Always start with clean database state
- Test both positive and negative scenarios

## Environment Setup
- Database URL provided via GitHub repository secret: DATABASE_URL
- Local development uses `.env.local` file  
- Format: `postgresql://username:password@host:port/database`
- Use `@postgres` client library for database connections
- **AGENT MUST EXECUTE TESTS**: Always run the full test cycle to verify changes

## Common Patterns

### Adding New Database Features
1. Create migration file in appropriate `apps/*/migrations/` folder
2. Add corresponding pgTAP tests in `apps/test/tests/`
3. Run full test cycle to verify

### Adding CLI Commands
1. Create function in `commands/` folder
2. Export async function
3. Wire into `cli.ts`
4. Follow existing patterns for error handling

## Prototyping Mode
- Always start with empty database (no migration compatibility needed)
- Rapid iteration is preferred over backward compatibility
- Use `dropall --confirm` liberally for clean testing