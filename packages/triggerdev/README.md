# @semantius/triggerdev

TriggerDev integration for Semantius Core. Run database migrations from
[TriggerDev](https://trigger.dev) tasks using pre-bundled SQL content.

Unlike the CLI (which reads SQL files from disk at runtime), this package
bundles all SQL migration files at build time so they can be executed from
serverless/edge environments like TriggerDev where the filesystem is not
available.

## Prerequisites

- Node.js 18+
- pnpm 8+
- [TriggerDev](https://trigger.dev) v3 account and project
- PostgreSQL database

---

## Setup

### 1. Install dependencies

From the project root:

```bash
pnpm install
```

### 2. Initialise TriggerDev in your project

If you have not already set up TriggerDev, run the initialisation wizard from
your application directory:

```bash
npx trigger.dev@latest init
```

This creates a `trigger/` directory and adds the necessary configuration files
(`.trigger/`, `trigger.config.ts`).

### 3. Configure environment variables

Your environment must have the following variables set before deploying or
running locally.

#### Required

| Variable            | Description                                                  |
| ------------------- | ------------------------------------------------------------ |
| `DATABASE_URL`      | PostgreSQL connection URL, e.g. `postgresql://user:pass@host/db?sslmode=require` |
| `TRIGGER_SECRET_KEY`| TriggerDev API secret key — found in your project's **API keys** settings page |
| `TRIGGER_PROJECT_ID`| TriggerDev project ID (e.g. `proj_xxxxxxxxxxxxxxxx`) — found in your project settings |

#### Optional

| Variable              | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `TRIGGER_API_URL`     | TriggerDev API base URL (default: `https://api.trigger.dev`) |

Copy `.env.example` to `.env.local` (for local dev) or set these variables in
your deployment environment / CI:

```bash
cp .env.example .env.local
# then edit .env.local:
DATABASE_URL='postgresql://user:pass@host:5432/db?sslmode=require'
TRIGGER_SECRET_KEY='tr_dev_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
TRIGGER_PROJECT_ID='proj_xxxxxxxxxxxxxxxx'
```

### 4. Build the @semantius/triggerdev package

The build step:
1. Compiles `@semantius/core` (shared migration logic) to CommonJS.
2. Bundles all `apps/*/migrations/*.sql` files into a TypeScript file
   (`src/migrations-bundle.ts`) — the `test` app is excluded.
3. Compiles `@semantius/triggerdev` to CommonJS.

Run from the **project root**:

```bash
pnpm run triggerdev:build
```

> **Important:** Re-run `pnpm run triggerdev:build` every time you add, modify,
> or remove SQL migration files and before deploying to TriggerDev.

### 5. Create a TriggerDev task

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

### 6. Run locally for development

```bash
npx trigger.dev@latest dev
```

This starts the TriggerDev dev server which connects to your TriggerDev project
and allows you to trigger tasks locally.

### 7. Deploy to TriggerDev

```bash
npx trigger.dev@latest deploy
```

### 8. Trigger migrations from your application

```typescript
import { tasks } from "@trigger.dev/sdk/v3";

// Run all bundled migrations
await tasks.trigger("run-migrations", {});

// Run specific modules only (_core is always included automatically)
await tasks.trigger("run-migrations", {
  modules: ["nwind"],
});
```

---

## API

### `migrate(databaseUrl, modules?, options?)`

Runs database migrations for the specified modules using bundled SQL content.

Acquires a PostgreSQL advisory lock before starting to prevent concurrent
migration runs.

| Parameter     | Type            | Description                                                             |
| ------------- | --------------- | ----------------------------------------------------------------------- |
| `databaseUrl` | `string`        | PostgreSQL connection URL                                               |
| `modules`     | `string[]`      | Module names to migrate. Defaults to all bundled apps when omitted.    |
| `options`     | `MigrateOptions`| Optional: `{ verbose: boolean }` — enables detailed logging.           |

The `_core` module is always prepended automatically regardless of what is
passed in `modules`.

### `getBundledAppNames(): string[]`

Returns the list of app names that have bundled SQL migrations.

### `getBundledMigrations(appName: string): MigrationFile[]`

Returns the migrations for a specific app, sorted by filename.

---

## How it works

1. **Build time** — `scripts/bundle-sql.ts` walks `apps/*/migrations/*.sql`
   and embeds the SQL content as TypeScript string literals in
   `src/migrations-bundle.ts` (the `test` app is excluded since pgTAP is not
   needed in production).

2. **Runtime** — `migrate()`:
   - Connects to the database and acquires a PostgreSQL advisory lock
     (`pg_try_advisory_lock`) to prevent concurrent migration runs.
   - For each app, ensures the `_versions` tracking table exists.
   - Iterates bundled migrations, skipping any already recorded in `_versions`.
   - Executes each new migration inside a transaction and records the version
     on success.
   - Releases the advisory lock when all apps are processed.

---

## Monorepo structure

This package is part of the Semantius Core monorepo:

```
packages/
├── core/        @semantius/core   — shared migration logic (Deno + Node.js)
├── cli/         @semantius/cli    — Deno CLI (deno task migrate, dropall, etc.)
└── triggerdev/  @semantius/triggerdev — TriggerDev integration (this package)
```

The migration logic (`ensureVersionsTable`, `executeSQL`, `executeMigrations`)
lives exclusively in `packages/core/src/migrate.ts` and is compiled to
CommonJS before being consumed here. No logic is duplicated.
