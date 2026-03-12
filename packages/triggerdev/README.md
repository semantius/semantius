# @semantius/triggerdev

TriggerDev integration for Semantius Core. Run database migrations from [TriggerDev](https://trigger.dev) tasks using pre-bundled SQL content.

Unlike the CLI (which reads SQL files from disk), this package bundles all SQL
migration files into the compiled output so that migrations can be executed from
serverless/edge environments where the filesystem is not available.

## Prerequisites

- Node.js 18+
- pnpm 8+
- [TriggerDev](https://trigger.dev) account and project set up
- PostgreSQL database

## Setup

### 1. Install dependencies

From the project root:

```bash
pnpm install
```

### 2. Bundle SQL migrations

Before building the package you must bundle the SQL files:

```bash
# From the project root:
deno task bundle-sql
# or via pnpm:
pnpm run bundle-sql
```

This reads all `apps/*/migrations/*.sql` files and embeds their content into
`packages/triggerdev/src/migrations-bundle.ts`.

> **Important:** Re-run `bundle-sql` every time you add, modify, or remove SQL
> migration files and before deploying to TriggerDev.

### 3. Build the package

```bash
pnpm --filter @semantius/triggerdev build
# or from root:
pnpm run triggerdev:build
```

### 4. Create a TriggerDev task

```typescript
// trigger/migration.ts
import { task } from "@trigger.dev/sdk/v3";
import { migrate } from "@semantius/triggerdev";

export const migrationTask = task({
  id: "run-migrations",
  run: async (payload: { modules?: string[] }) => {
    await migrate(process.env.DATABASE_URL!, payload.modules, {
      verbose: true,
    });
  },
});
```

### 5. Trigger migrations from your application

```typescript
import { tasks } from "@trigger.dev/sdk/v3";

// Run all migrations
await tasks.trigger("run-migrations", {});

// Run specific modules only
await tasks.trigger("run-migrations", {
  modules: ["_core", "nwind"],
});
```

## API

### `migrate(databaseUrl, modules?, options?)`

Runs database migrations for the specified modules.

| Parameter    | Type            | Description                                                          |
| ------------ | --------------- | -------------------------------------------------------------------- |
| `databaseUrl`| `string`        | PostgreSQL connection URL                                            |
| `modules`    | `string[]`      | Module names to migrate. Defaults to all bundled apps.              |
| `options`    | `MigrateOptions`| Optional: `{ verbose: boolean }` — enables detailed logging.        |

The `_core` module is always prepended automatically.

### `getBundledAppNames(): string[]`

Returns the list of app names that have bundled SQL migrations.

### `getBundledMigrations(appName: string): MigrationFile[]`

Returns the migrations for a specific app, sorted by filename.

## How it works

1. The `bundle-sql.ts` build script walks `apps/*/migrations/*.sql` and embeds
   the SQL content as TypeScript string literals in `migrations-bundle.ts`.

2. At runtime the `migrate()` function:
   - Connects to the database with an advisory lock (prevents concurrent runs).
   - Calls `ensureVersionsTable()` to create the `_versions` tracking table.
   - Iterates bundled migrations, skipping any already recorded in `_versions`.
   - Executes each new migration in a transaction, recording the version on success.
   - Releases the advisory lock when done.

## Environment Variables

| Variable        | Description                    |
| --------------- | ------------------------------ |
| `DATABASE_URL`  | PostgreSQL connection URL      |
