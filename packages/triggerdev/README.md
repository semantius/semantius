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
- [TriggerDev](https://trigger.dev) v3/v4 account and project
- PostgreSQL database

---

## Quick start (deploy to TriggerDev)

```bash
# 1. From the repo root — build the package and bundle SQL migrations
pnpm run triggerdev:build

# 2. Set required environment variables
cp .env.example .env.local
# Edit .env.local:
#   DATABASE_URL='postgresql://user:pass@host:5432/db?sslmode=require'
#   TRIGGER_SECRET_KEY='tr_dev_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
#   TRIGGER_PROJECT_ID='proj_xxxxxxxxxxxxxxxx'

# 3. Deploy the migration task
cd packages/triggerdev
pnpm run deploy
# or for local development:
pnpm run dev
```

That's it. The `trigger/migration.ts` file and `trigger.config.ts` are already
included in this package — no extra setup required.

---

## Trigger migrations from your application

Once deployed, trigger the task from anywhere in your application:

```typescript
import { tasks } from "@trigger.dev/sdk/v3";

// Run _core migrations only
await tasks.trigger("run-migrations", {
  databaseUrl: process.env.DATABASE_URL!,
  modules: ["_core"],
});

// Run _core + nwind migrations
await tasks.trigger("run-migrations", {
  databaseUrl: process.env.DATABASE_URL!,
  modules: ["_core", "nwind"],
});

// Run all bundled migrations
await tasks.trigger("run-migrations", {
  databaseUrl: process.env.DATABASE_URL!,
});
```

### Example payloads (JSON)

```json
{ "databaseUrl": "postgresql://user:pass@host:5432/db", "modules": ["_core"] }
```

```json
{ "databaseUrl": "postgresql://user:pass@host:5432/db", "modules": ["_core", "nwind"] }
```

```json
{ "databaseUrl": "postgresql://user:pass@host:5432/db" }
```

The `_core` module is always migrated first regardless of what `modules`
contains. If `databaseUrl` is omitted in the payload, the task falls back to
the `DATABASE_URL` environment variable set on the TriggerDev worker.

---

## Setup details

### 1. Install dependencies

From the project root:

```bash
pnpm install
```

### 2. Configure environment variables

| Variable            | Description                                                               |
| ------------------- | ------------------------------------------------------------------------- |
| `DATABASE_URL`      | PostgreSQL connection URL, e.g. `postgresql://user:pass@host/db`         |
| `TRIGGER_SECRET_KEY`| TriggerDev API secret key — found in your project's **API keys** page    |
| `TRIGGER_PROJECT_ID`| TriggerDev project ID (e.g. `proj_xxxxxxxxxxxxxxxx`)                     |

```bash
cp .env.example .env.local
```

### 3. Build

The build step:
1. Compiles `@semantius/core` (shared migration logic) to CommonJS.
2. Bundles all `apps/*/migrations/*.sql` files into `src/migrations-bundle.ts`
   (the `test` app is excluded).
3. Compiles `@semantius/triggerdev` to CommonJS.

```bash
# From repo root:
pnpm run triggerdev:build
```

> **Important:** Re-run `pnpm run triggerdev:build` every time you add, modify,
> or remove SQL migration files and before redeploying.

### 4. Run locally for development

```bash
cd packages/triggerdev
pnpm run dev
# or: npx trigger.dev@latest dev
```

### 5. Deploy to TriggerDev

```bash
cd packages/triggerdev
pnpm run deploy
# or: npx trigger.dev@latest deploy
```

---

## Project structure

The deployable TriggerDev project is self-contained in `packages/triggerdev`:

```
packages/triggerdev/
├── trigger/
│   └── migration.ts       # Task entry point (re-exports migrationTask)
├── trigger.config.ts      # TriggerDev project configuration
├── src/
│   ├── index.ts           # Library exports (migrationTask, migrate, etc.)
│   ├── migrate.ts         # Core migration logic using bundled SQL
│   └── migrations-bundle.ts  # Auto-generated SQL bundle (build artefact)
└── package.json
```

The `trigger/migration.ts` file is the TriggerDev entry point. It re-exports
`migrationTask` from the library source. TriggerDev's bundler compiles and
deploys it together with all its dependencies.

---

## Custom task (advanced)

If you need to customise the task, copy `trigger/migration.ts` to your own
TriggerDev project and modify it:

```typescript
// your-app/trigger/migration.ts
import { task } from "@trigger.dev/sdk/v3";
import { migrate } from "@semantius/triggerdev";

export const migrationTask = task({
  id: "run-migrations",
  run: async (payload: { databaseUrl?: string; modules?: string[] }) => {
    const databaseUrl = payload.databaseUrl ?? process.env.DATABASE_URL!;
    await migrate(databaseUrl, payload.modules, { verbose: true });
  },
});
```

---

## API

### `migrationTask`

The ready-to-use TriggerDev task exported from this package.

**Task ID:** `run-migrations`

**Payload:**

| Field         | Type       | Required | Description                                                           |
| ------------- | ---------- | -------- | --------------------------------------------------------------------- |
| `databaseUrl` | `string`   | No\*     | PostgreSQL connection URL. Falls back to `DATABASE_URL` env var.      |
| `modules`     | `string[]` | No       | Apps to migrate. Defaults to all bundled apps. `_core` always first.  |

\*Either `databaseUrl` in the payload or `DATABASE_URL` as an env var is required.

---

### `migrate(databaseUrl, modules?, options?)`

Low-level function for running migrations programmatically.

Acquires a PostgreSQL advisory lock to prevent concurrent migration runs.

| Parameter     | Type            | Description                                                          |
| ------------- | --------------- | -------------------------------------------------------------------- |
| `databaseUrl` | `string`        | PostgreSQL connection URL                                            |
| `modules`     | `string[]`      | Module names to migrate. Defaults to all bundled apps when omitted. |
| `options`     | `MigrateOptions`| Optional: `{ verbose: boolean }` — enables detailed logging.        |

---

### `getBundledAppNames(): string[]`

Returns the list of app names that have bundled SQL migrations.

### `getBundledMigrations(appName: string): MigrationFile[]`

Returns the migrations for a specific app, sorted by filename.

---

## Monorepo structure

```
packages/
├── core/        @semantius/core       — shared migration logic (Deno + Node.js)
├── cli/         @semantius/cli        — Deno CLI (deno task migrate, dropall, etc.)
└── triggerdev/  @semantius/triggerdev — TriggerDev integration (this package)
```

The migration logic (`ensureVersionsTable`, `executeSQL`, `executeMigrations`)
lives exclusively in `packages/core/src/migrate.ts`. No logic is duplicated.
