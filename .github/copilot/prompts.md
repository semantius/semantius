# Semantius Core Coding Guidelines

You are working on Semantius Core, a database-first backend system. The rules for agents are in AGENTS.md. Follow these specific guidelines:

## Architecture Understanding
- This is NOT a typical web application
- Business logic lives in PostgreSQL functions, not application code
- Security is enforced at the database level through RLS and RBAC
- The Deno CLI is only for deployment, migration, and testing

## When Working with Database Code
- Write SQL functions instead of TypeScript business logic
- Use PostgreSQL's advanced features (RLS, custom types, functions)
- Follow the numbered migration pattern (0010_, 0020_, etc.)
- Always consider security implications and RLS policies

## When Working with CLI Code
- Use Deno-specific imports and patterns
- Leverage the import map defined in deno.json
- Follow the existing command pattern in the commands/ folder
- Use the centralized getDatabaseUrl() function

## Testing Requirements
- Write pgTAP tests for all database functionality
- **ALWAYS EXECUTE**: Run the full test cycle after any changes on the local pgdocker containers: `./pgdocker/pg-cli-retest.sh`, and `./pgdocker/pg-ext-retest.sh` for the extension path
- Never run `dropall` against a remote database, nor `retest` or `reset`, which drop everything first
- Test both success and failure scenarios
- Consider edge cases and security boundaries
- **AGENT MUST VERIFY**: Execute tests to ensure nothing is broken before completing tasks

## Development Workflow
- After a release, migrations are forward only and additive only (AGENTS.md)
- Start each test cycle from a fresh local container
- Prioritize correctness
- Focus on PostgreSQL best practices

## Code Quality
- Prefer SQL functions over application-level business logic
- Use meaningful names for database objects
- Document complex RLS policies
- Keep CLI commands simple and focused

Remember: This project inverts the typical web application pattern - the database is the application, and the CLI is just tooling.