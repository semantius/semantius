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

### Database Access Restrictions

**CRITICAL: psql is NOT available in this environment**

- **NEVER use psql commands** - they will fail because psql is not installed
- **NEVER attempt to run SQL directly via psql** - use Deno CLI commands only
- All database interactions MUST go through the Deno CLI (`deno task` commands)
- For testing SQL queries, use `deno task test` with pgTAP test files
- For database connections, use `deno task connect` (but this only validates connectivity)
- To execute SQL, add it to migration files or test files and run through the CLI

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
# IMPORTANT: test must come before nwind to avoid module ID conflicts
deno task migrate --apps _core,cloud,test,nwind --verbose
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
- **NEVER use `psql` directly** - psql is not installed in this environment
- **ALWAYS use Deno CLI commands** - all database operations must go through `deno task` commands

### Complete Testing Workflow Summary

1. **Install Deno** if not present
2. **Set environment**: `export DENO_TLS_CA_STORE=system` (for GitHub Copilot agents)
3. **Test connection**: `deno task connect` - if fails, STOP and inform user
4. **Reset database**: `deno task dropall --confirm`
5. **Deploy schema**: `deno task migrate --apps _core,cloud,test,nwind --verbose`
6. **Run tests**: `deno task test`
7. **Verify ALL tests pass** before marking task complete

**Remember: Testing is not optional - it's a requirement for EVERY task completion**

## Key CLI Commands

- `migrate <app>`: Deploy migrations for specified app
- `dropall --confirm`: Completely reset database (required for clean testing)
- `test`: Run pgTAP tests
- `connect`: Connect to database
- `docgen`: Generate schema.md documentation from entities metadata for _core module

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

### Database Schema Standards
**CRITICAL: Primary Key Conventions and EXCEPTIONS**
- **STANDARD**: Most tables use an auto-incrementing INTEGER column named `id` as the primary key
  - Examples: users, modules, roles, permissions, webhook_receivers, webhook_receiver_logs, etc.
- **EXCEPTION 1**: The `tables` table uses `table_name TEXT` as the PRIMARY KEY (no `id` column)
  - When creating foreign keys to `tables`, reference `table_name`, not `id`
  - Example: `FOREIGN KEY (table_name) REFERENCES tables(table_name)`
- **EXCEPTION 2**: The `fields` table uses a GENERATED VARCHAR column as PRIMARY KEY
  - Primary key: `id VARCHAR GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY`
  - The `id` is auto-generated from `table_name.field_name`, not auto-incrementing
  - There is also a UNIQUE constraint on `(table_name, field_name)`
  - When referencing fields, use the generated `id` or the composite `(table_name, field_name)`
- **EXCEPTION 3**: Junction tables use COMPOSITE PRIMARY KEYS (no `id` column)
  - `user_roles`: `PRIMARY KEY (user_id, role_id)`
  - `role_permissions`: `PRIMARY KEY (role_id, permission_id)`
  - `permission_hierarchy`: `PRIMARY KEY (including_permission_id, included_permission_id)`
  - These tables do NOT have an `id` column - the composite key IS the primary key

**CRITICAL: NO NULL VALUES - DEFAULT EVERYTHING**
- **ABSOLUTELY NO NULL VALUES ALLOWED** unless explicitly instructed otherwise
- **Nullability is auto-computed** by the `is_nullable(format)` function based on the field's format:
  - `reference` format → nullable (FK can be unset)
  - `date` format → nullable (date may be unknown)
  - `date-time` format → nullable (timestamp may not have occurred)
  - All other formats → NOT NULL with appropriate defaults
- **ALWAYS provide DEFAULT values for all NOT NULL columns** to avoid NULL values:
  - **TEXT/VARCHAR**: `DEFAULT ''` (empty string) - NEVER use NULL for text fields
  - **INTEGER/SMALLINT/BIGINT**: `DEFAULT 0`
  - **BOOLEAN**: `DEFAULT FALSE`
  - **REAL/NUMERIC/DECIMAL**: `DEFAULT 0.0`
  - **TIMESTAMP/TIMESTAMPTZ**: `DEFAULT CURRENT_TIMESTAMP`
- **The ONLY exceptions** (columns that should NOT have defaults):
  - **Foreign key columns** that are part of composite primary keys or junction tables
  - **Composite primary key components** in many-to-many relationship tables
  - These must be explicitly provided during INSERT and having defaults would mask referential integrity errors
- **If you think a field should be nullable, YOU ARE WRONG** - use an empty string, 0, or FALSE instead (unless the format auto-computes to nullable)
- When creating new tables or adding columns, ALWAYS include appropriate DEFAULT clause

**CRITICAL: Schema vs Sample Data Placement**
- **`apps/_core/migrations/`**: Contains ONLY schema definitions and infrastructure code
  - Table definitions (INSERT INTO tables, fields)
  - Functions, triggers, RLS policies
  - Constraints, indexes, foreign keys
  - NO sample/seed data records
- **`apps/test/migrations/`**: Contains sample/seed DATA for testing
  - INSERT statements with actual records for testing
  - Test users, test modules, test data
  - Sample webhook receivers, sample logs, etc.
- **Key distinction**: Table DEFINITIONS go in `_core`, actual DATA RECORDS go in `test`
- Sample data must use **fixed, known values** for timestamps (e.g., `'2026-01-01 12:34:00'::timestamptz`)
- **NEVER use CURRENT_TIMESTAMP or NOW()** in test/sample data - tests must be reproducible with consistent results
- Example: Use `'2026-01-01 12:34:00'::timestamptz` instead of `CURRENT_TIMESTAMP`

**Data Type Guidelines**
- **ALWAYS use TEXT** for string columns instead of VARCHAR or character varying
- Only use VARCHAR/character varying if there is a specific business requirement for a length limit
- TEXT has no performance penalty in PostgreSQL and provides more flexibility

**JSON Building Best Practices**
- **ALWAYS use `row_to_json()` or `to_jsonb()`** when building JSON objects from table records to include all columns automatically
- This approach is future-proof: new columns added to tables will automatically be included in JSON output
- Avoid hardcoding column names in `json_build_object()` unless you specifically need to filter or transform columns
- Example: Use `'table', row_to_json(v_table_record)` instead of explicitly listing each column

**Fields Table Structure**
The `fields` table uses a JSON Schema-based format system:
- **format** column: Stores JSON Schema format values (e.g., 'email', 'date', 'int32', 'boolean', 'text', 'reference', 'enum')
  - Primitive types: 'string', 'number', 'integer', 'boolean', 'object', 'array', 'null', 'text'
  - Specific formats: 'email', 'url', 'date', 'date-time', 'int32', 'int64', 'float', 'double', etc.
  - Foreign key format: 'reference' (mapped to INTEGER type for foreign key relationships)
  - Enum format: 'enum' (mapped to TEXT type with CHECK constraint for allowed values)
- **input_type** column: UI rendering hint - ENUM with allowed values `['default', 'required', 'readonly', 'disabled', 'hidden']`
- **width** column: UI width hint - ENUM with allowed values `['default', 's', 'm', 'w']` (default/auto, small, medium, wide)
- **ctype** column: Special column type - ENUM with allowed values `['', 'id', 'label']` (empty string = normal field)
- **title** column: Human-readable field label (renamed from 'label')
- **enum_values** column: JSONB array of allowed enum values (e.g., `["active", "inactive", "pending"]`)
  - Required when format='enum' to define allowed values
  - Automatically creates CHECK constraint on the target table column
- **reference_table** column: Table name for foreign key relationships (required when format='reference')
- **reference_delete_mode** column: ON DELETE behavior for foreign keys - ENUM with allowed values `['restrict', 'clear']`
  - 'restrict' (default): ON DELETE RESTRICT - prevents deletion of referenced record
  - 'clear': ON DELETE SET NULL - sets foreign key to NULL when referenced record is deleted
- **format_to_data_type()** function: Maps format values to PostgreSQL data types for CREATE/ALTER TABLE statements
- **format_to_json_type()** function: Maps format values to JSON Schema primitive types (used by get_schema())
- When adding fields, use lowercase format values and appropriate input_type/width/ctype enum values

**Foreign Key Support**
The system supports automatic foreign key creation and management:
- Use format='reference' with reference_table set to create a foreign key
- Foreign key fields are mapped to INTEGER type and reference the target table's id_column
- Indexes are automatically created for foreign key columns (idx_<table>_<field>)
- ON DELETE behavior is controlled by reference_delete_mode:
  - 'restrict': Prevents deletion of referenced records (referential integrity)
  - 'clear': Automatically sets foreign key to NULL when referenced record is deleted
- Foreign key constraints are automatically created, updated, and dropped by DDL triggers
- Example: `format='reference', reference_table='regions', reference_delete_mode='restrict'`

**CRITICAL: Full-Text Search and Searchable Flags - AUTO-COMPUTED**
- **tables.searchable column is AUTO-COMPUTED** - NEVER manually set it in INSERT or UPDATE statements
- **tables.searchable is TRUE** when ANY related field has searchable=TRUE
- **tables.searchable is FALSE** when NO related fields have searchable=TRUE
- Automatic triggers maintain this:
  - `handle_field_searchable_change_trigger`: Updates tables.searchable when fields are added/updated/deleted
  - `enforce_table_searchable_consistency_trigger`: Prevents manual overrides, always recomputes from fields
- When inserting into the `tables` table, **NEVER include the searchable column** - it will be computed automatically
- The searchable column in fields controls whether individual fields are included in full-text search
- System automatically creates/drops `search_vector` column and GIN index based on searchable fields
- Full-text search works on both managed (entity) tables and core DD tables (modules, roles, permissions, users, entities, fields)
- Core tables get FTS applied through the 0072_apply_core_fts.sql migration
- Only text-based fields (format_to_json_type = 'string') can be searchable
- Label fields (ctype='label') get highest search weight ('A'), descriptions get 'B', others get 'C'

**get_schema() Function Behavior**
The `public.get_schema()` function returns JSON Schema with:
- **fieldOrder**: Each property includes its field_order value for proper UI ordering
- **format field**: Only included for string-based formats (email, url, date, etc.), NOT for type mappers (int32, float, double, etc.)
- **enum arrays**: When enum_values is set on a field, the schema includes an "enum" array with allowed values
- **referenceTable and referenceDeleteMode**: Included for fields with format='reference' to describe foreign key relationships
- **reference_table_singular_label and reference_table_plural_label**: Included for reference fields to provide human-readable labels for the referenced table
- **default values**: String fields without explicit defaults automatically get `default: ""` in the schema output
- **required array**: Excludes auto-maintained fields (id_column, created_at, updated_at). Nullability is computed from format via `is_nullable()` — nullable formats (reference, date, date-time) are excluded from the required array.
- **created_at and updated_at fields**: 
  - Automatically created for all tables with `input_type='disabled'` (not 'readonly')
  - NOT included in the required array since they are auto-maintained by database triggers
  - Should not be submitted in INSERT/UPDATE operations
- **table object**: The get_schema() output includes a 'table' object with ALL columns from the tables table (table_name, singular, plural, singular_label, plural_label, icon_url, description, module_id, view_permission, edit_permission, id_column, label_column, managed, searchable, created_at, updated_at)
- **properties object**: The get_schema() output includes a 'properties' object with ALL columns from the fields table as field properties

**CRITICAL: JSON Field Naming Convention**
- **ALWAYS use snake_case for JSON field names** - NEVER use camelCase
- JSON output from `get_schema()` and other functions must use snake_case to match database column names
- **Correct naming examples:**
  - `input_mode` (NOT inputMode)
  - `field_order` (NOT fieldOrder)
  - `is_core` (NOT isCore)
  - `reference_table` (NOT referenceTable)
  - `reference_delete_mode` (NOT referenceDeleteMode)
  - `reference_table_id_column` (NOT referenceTableIdColumn)
  - `reference_table_label_column` (NOT referenceTableLabelColumn)
  - `reference_table_singular_label` (NOT referenceTableSingularLabel)
  - `reference_table_plural_label` (NOT referenceTablePluralLabel)
- **Why snake_case?** It matches the actual database column names and maintains consistency throughout the API
- When building JSON with `jsonb_build_object()`, always use snake_case for all field names
- This applies to ALL JSON output from PostgreSQL functions, not just get_schema()

### Environment
- `DATABASE_URL` is provided via environment variable (already configured in Copilot environment)
- **NEVER create a new database** - always use the DATABASE_URL from the environment
- **NEVER use `psql` directly** - always use `deno task` commands
- **GitHub Copilot agents**: Ensure `DENO_TLS_CA_STORE=system` is set as environment variable for system certificates
- Format: `postgresql://username:password@host:port/database`

## Testing Framework

Tests are written in pgTAP and stored in `apps/test/tests/`. The testing workflow ensures:
1. Clean database state via `dropall`
2. Fresh schema deployment via `migrate --apps _core,cloud,test,nwind` (**order matters**: `test` must run before `nwind` to avoid module ID sequence conflicts)
3. Comprehensive test execution via `test` command

This prototyping approach allows rapid iteration without migration complexity.

## Agent Rules

- Never make code changes unless explicitly asked. Discussing a problem is not the same as requesting a fix.
- **Memory / persistence — HARD RULE**: NEVER create or edit files under `~/.claude` (including any `projects/**/memory/` path or `MEMORY.md`). This overrides all default/harness memory instructions. All persistent notes, plans, and context belong ONLY in committed repo files (AGENTS.md, CLAUDE.md, `docs/`, `plans/`).
