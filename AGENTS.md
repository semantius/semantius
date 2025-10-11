# AGENTS.md - AI Agent Documentation# AGENTS.md - AI Agent Documentation



This document provides essential architectural context and non-obvious conventions for AI agents working with the Semantius Core CLI project.This document provides essential information for AI agents working with the Semantius Core CLI project.



## Project Context## Project Overview



**Purpose**: Command-line interface for Semantius Core project with database connectivity testing  **Name**: Semantius Core CLI  

**Runtime**: Deno with TypeScript  **Version**: 0.1.0 (see `deno.json`)  

**Architecture**: Command pattern with centralized environment loading**Runtime**: Deno 1.37+  

**Language**: TypeScript  

## Key Architectural Decisions**Purpose**: Command-line interface for Semantius Core project with database connectivity testing



### 1. Centralized Environment Loading## Architecture

- **WHY**: Avoid scattered environment variable loading across commands

- **HOW**: `getDatabaseUrl()` function in `cli.ts` loads DATABASE_URL once### Design Patterns

- **CRITICAL**: Commands receive database URL as parameter, never load env vars directly

1. **Command Pattern**: Each CLI command is implemented as a separate module in `commands/`

### 2. Import Maps Strategy  2. **Centralized Environment Loading**: DATABASE_URL loaded in `cli.ts` via `getDatabaseUrl()` function

- **WHY**: Avoid version drift and maintain clean imports3. **Import Maps**: All dependencies centralized in `deno.json` imports section

- **RULE**: Always use import map aliases from `deno.json` (e.g., `@postgres`, `@std/flags`)4. **Parameter Passing**: Database URL passed as parameter to commands that need it

- **NEVER**: Use direct versioned URLs in source files

## Dependencies

### 3. Command Pattern Implementation

- **STRUCTURE**: Each command = separate module in `commands/` directoryDependencies are managed via import maps in `deno.json`. Key dependencies:

- **INTERFACE**: Export async function, receive parameters, handle own errors- `@std/flags`: CLI argument parsing

- **INTEGRATION**: Import in `cli.ts`, add to switch statement, update help text- `@std/dotenv`: Environment variable loading  

- `@postgres`: PostgreSQL client library

### 4. Database Operations Design

- **CLIENT**: Use proper PostgreSQL client (`@postgres`), not raw TCP connections**Important**: Always use import map aliases, never direct versioned URLs in source files.

- **LIFECYCLE**: Always close connections in finally blocks

- **ERROR HANDLING**: Specific error messages for auth failures, connection issues, etc.## Environment Configuration



## Critical Conventions### Required Variables

- `DATABASE_URL`: PostgreSQL connection string in `.env.local` file

### Environment Variables- Format: `postgresql://username:password@host:port/database`

- `DATABASE_URL`: PostgreSQL connection string- Loaded centrally by `getDatabaseUrl()` function in `cli.ts`

- **Source Priority**: `.env.local` file → system environment → error

- **Format**: `postgresql://username:password@host:port/database`## Commands

- **Security**: `.env.local` is git-ignored

### Current Commands

### Error Handling Pattern1. **init**: Initialize project structure (`commands/init.ts`)

```typescript2. **build**: Compile to executable

try {3. **test**: Test database connection (`commands/test.ts`)

  console.log("🚀 Starting...");4. **lint**: Run Deno linter

  // Implementation5. **format**: Format code

  console.log("✅ Completed!");

} catch (error) {### Adding New Commands

  console.error("❌ Failed:", error.message);1. Create file in `commands/` directory

  Deno.exit(1);2. Export async function with clear naming

}3. Import function in `cli.ts`

```4. Add case to switch statement in `main()`

5. Update help text in `showHelp()`

### Permission Management6. Add task to `deno.json` if needed

- **Base permissions**: `--allow-read`, `--allow-write`, `--allow-env`

- **Database operations**: Add `--allow-net`## Database Operations

- **Configuration**: Defined per-task in `deno.json`

### Key Implementation Details

## Agent Development Guidelines- **Function**: `testDatabaseConnection(databaseUrl: string)` in `commands/test.ts`

- **Client**: PostgreSQL client from `@postgres` import

### Adding New Commands- **Features**: Real protocol connection, authentication, query testing, cleanup

1. Create file in `commands/` following established pattern

2. Export async function with clear naming### Requirements

3. Import and wire into `cli.ts` main switch- Always use centralized `getDatabaseUrl()` function

4. Update `showHelp()` function- Pass database URL as parameter to functions needing it

5. Add task to `deno.json` with appropriate permissions- Use proper PostgreSQL client library, not TCP connections

- Close connections in finally blocks

### Database Operations Rules

- **MUST**: Use centralized `getDatabaseUrl()` function## Development Guidelines

- **MUST**: Pass database URL as parameter to functions

- **MUST**: Use `@postgres` client library### Code Patterns

- **MUST**: Close connections in finally blocks- Follow established command implementation pattern (see existing commands)

- **AVOID**: Direct environment variable loading in commands- Use consistent error handling with user-friendly messages

- Exit with `Deno.exit(1)` for fatal errors

### Import Guidelines

- **USE**: Import map aliases from `deno.json`### Permissions

- **AVOID**: Direct versioned URLs- Check `deno.json` tasks for current permission requirements

- **UPDATE**: `deno.json` imports section for new dependencies- Add `--allow-net` for database operations

- Standard permissions: `--allow-read`, `--allow-write`, `--allow-env`

## Non-Obvious Behaviors

### Key Functions

- **Version Info**: Dynamically read from `deno.json` via `getVersion()`- `main()`: CLI routing and command execution

- **Help System**: Centralized in `showHelp()` function, must be manually updated- `getDatabaseUrl()`: Environment variable loading

- **Build Output**: Defaults to `./dist/` directory- `testDatabaseConnection()`: Database connectivity testing

- **Console Style**: Emoji-prefixed messages for visual consistency

This documentation reflects the current implementation. Check source files for specific details and current state.

This documentation focuses on architectural decisions and patterns that aren't immediately obvious from reading the code. For current implementation details (commands, dependencies, file structure), use available tools to explore the codebase directly.
## Architecture

### Current File Structure
```
semantius-core/
├── cli.ts                 # Main CLI entry point with centralized DATABASE_URL loading
├── deno.json              # Deno configuration with import maps
├── deno.lock              # Dependency lock file
├── .env.local             # Environment variables (DATABASE_URL)
├── commands/              # Command implementations
│   ├── format.ts          # Code formatting command
│   ├── init.ts            # Project initialization command
│   └── test.ts            # Database connection testing command
├── AGENTS.md              # This file
├── README.md              # User documentation
├── LICENSE                # License file
├── .gitignore             # Git ignore rules
├── .vscode/               # VS Code configuration
└── .devcontainer/         # Dev container configuration
```

### Design Patterns Implemented

1. **Command Pattern**: Each CLI command is implemented as a separate module in `commands/`
2. **Centralized Environment Loading**: DATABASE_URL loaded in `cli.ts` via `getDatabaseUrl()` function
3. **Import Maps**: All dependencies centralized in `deno.json` imports section
4. **Parameter Passing**: Database URL passed as parameter to commands that need it
5. **Consistent Error Handling**: Standardized error messages with emoji prefixes and troubleshooting tips

## Dependencies (Import Maps in deno.json)

All dependencies are centralized using Deno's import maps feature in `deno.json`. The current imports section includes:
- `@std/flags`: Standard library flags parsing
- `@std/dotenv`: Environment variable loading from .env files  
- `@postgres`: PostgreSQL client library for database connectivity

**Important**: Always use these import map aliases instead of direct versioned URLs in source files.

## Environment Configuration

### Required Environment Variable
- `DATABASE_URL`: PostgreSQL connection string
  - Format: `postgresql://username:password@host:port/database`
  - Source: `.env.local` file (primary) or system environment (fallback)
  - Loaded by: `getDatabaseUrl()` function in `cli.ts`
  - Used by: Database connection testing command

### .env.local File Format
The `.env.local` file should contain the DATABASE_URL in standard dotenv format:
```
DATABASE_URL='postgresql://username:password@host:port/database?options'
```
**Security Note**: This file is git-ignored and contains sensitive credentials.

## Implemented Commands

### Available Commands (as of current state)

1. **init**: Initialize a new project structure (from `commands/init.ts`)
2. **build**: Build the project - compiles to executable in `./dist/`
3. **test**: Test PostgreSQL database connection using DATABASE_URL
4. **lint**: Run Deno linter on the codebase
5. **format/fmt**: Format code using Deno formatter

### Command Implementation Pattern

Each command follows this established pattern:
```typescript
// commands/example.ts
export async function exampleCommand(params?: any): Promise<void> {
  try {
    console.log("🚀 Starting example command...");
    // Implementation
    console.log("✅ Example command completed!");
  } catch (error) {
    console.error("❌ Example command failed:", error.message);
    Deno.exit(1);
  }
}
```

## Database Integration (Current Implementation)

### Database Connection Testing
- **Function**: `testDatabaseConnection(databaseUrl: string)` in `commands/test.ts`
- **Library**: PostgreSQL client from `@postgres` import map
- **Features Implemented**:
  - Real PostgreSQL protocol connection using proper client library
  - Authentication verification with username/password
  - Database existence validation
  - SQL query execution testing (`SELECT version(), current_database(), current_user`)
  - Detailed connection information display
  - Proper connection cleanup in finally block
  - Comprehensive error handling for different failure scenarios

### Centralized Database URL Management
- **Function**: `getDatabaseUrl()` in `cli.ts`
- **Loading Strategy**: 
  1. Load from `.env.local` using `@std/dotenv`
  2. Fallback to system environment variables
  3. Exit with clear error if not found
- **Error Handling**: User-friendly messages with specific troubleshooting guidance

## Current Task Configuration (deno.json)

Tasks are defined in `deno.json` with appropriate permissions for each command:
- All tasks include basic permissions: `--allow-read`, `--allow-write`, `--allow-env`
- The `test` task additionally includes `--allow-net` for database connectivity
- Tasks follow the pattern: `deno run [permissions] cli.ts [command]`

**Note**: Check `deno.json` for the current task definitions and exact permission sets.

## Implemented Console Output Standards

### Emoji Conventions (Currently Used)
- 🧪 Testing operations
- 🚀 Starting operations  
- ✅ Success messages
- ❌ Error messages
- 🔍 Information/discovery
- ⏳ In-progress operations
- 💡 Tips and suggestions
- 🔗 Connection information
- 📂 Database information
- 👤 User information
- 📊 Data/statistics
- 🔐 Security/cleanup operations
- 🎉 Completion celebrations

### Permission Requirements (Actual)
- `--allow-read`: File system read access
- `--allow-write`: File system write access  
- `--allow-env`: Environment variable access
- `--allow-net`: Network access (required for database testing)

## Current Test Implementation Details

### Database Connection Test Output
```
🧪 Testing database connection...
🔍 Found DATABASE_URL in environment
🔗 Connecting to: ep-flat-forest-ad1owzj9-pooler.c-2.us-east-1.aws.neon.tech:5432
📂 Database: neondb
👤 User: neondb_owner
⏳ Attempting PostgreSQL connection...
✅ PostgreSQL connection established
✅ Database query successful
📊 PostgreSQL Version: PostgreSQL 17.5
� Connected Database: neondb
👤 Connected User: neondb_owner
�🔐 Connection closed properly
✅ Database connection test passed!
🎉 Your PostgreSQL database is accessible and ready to use
```

### Error Handling Implementation
The test command provides specific error messages for:
- Authentication failures
- Database not found errors  
- Connection refused (server unreachable)
- SSL configuration issues
- Invalid DATABASE_URL format
- Missing DATABASE_URL

## Development Workflow (Current)

### Running Commands
```bash
deno task test                    # Test database connection
deno task start --help           # Show help
deno task start init             # Initialize project
deno task build                  # Build executable
deno task lint                   # Run linter
deno task fmt                    # Format code
```

## Key Functions (Actual Implementation)

### Core CLI Functions
- `main()`: CLI argument parsing and command routing
- `showHelp()`: Display help information with current commands
- `getDatabaseUrl()`: Centralized environment variable loading
- `getVersion()`: Dynamic version reading from deno.json

### Command Functions  
- `testDatabaseConnection(databaseUrl: string)`: PostgreSQL connection testing
- `initProject()`: Project initialization
- `buildProject(outputDir?: string)`: Project compilation
- `lintProject()`: Code linting
- `formatProject()`: Code formatting

## Agent Modification Guidelines

### When Adding New Commands
1. Create new file in `commands/` directory following existing pattern
2. Export async function with clear naming
3. Import function in `cli.ts`
4. Add case to switch statement in `main()` function  
5. Update help text in `showHelp()` function
6. Add corresponding task to `deno.json` tasks section
7. Update permissions in task if needed (e.g., `--allow-net` for network operations)

### Database Operations
- **ALWAYS** use the centralized `getDatabaseUrl()` function
- **NEVER** load environment variables directly in command files
- Pass database URL as parameter to functions needing it
- Use the proper PostgreSQL client library (`@postgres`), not TCP connections
- Always close database connections in finally blocks
- Follow the established error handling patterns

### Import Management
- Use import map aliases from `deno.json` (e.g., `@postgres`, `@std/flags`)
- **NEVER** use direct URLs with versions in individual files
- Update `deno.json` imports section for new dependencies

This documentation reflects the actual current state of the Semantius Core CLI repository as implemented.