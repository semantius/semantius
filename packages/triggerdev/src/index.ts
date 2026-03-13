/**
 * @semantius/triggerdev
 *
 * TriggerDev integration for Semantius Core.
 * Exports a ready-to-use `migrationTask` and the underlying `migrate()` function.
 *
 * @example Deploy the pre-built task
 * ```typescript
 * // trigger/migration.ts  (re-export the ready-made task)
 * export { migrationTask } from "@semantius/triggerdev";
 * ```
 *
 * @example Trigger _core migrations
 * ```typescript
 * import { tasks } from "@trigger.dev/sdk/v3";
 * await tasks.trigger("run-migrations", {
 *   databaseUrl: process.env.DATABASE_URL!,
 *   modules: ["_core"],
 * });
 * ```
 *
 * @example Trigger _core + nwind migrations
 * ```typescript
 * import { tasks } from "@trigger.dev/sdk/v3";
 * await tasks.trigger("run-migrations", {
 *   databaseUrl: process.env.DATABASE_URL!,
 *   modules: ["_core", "nwind"],
 * });
 * ```
 *
 * @example Trigger all bundled migrations
 * ```typescript
 * import { tasks } from "@trigger.dev/sdk/v3";
 * await tasks.trigger("run-migrations", {
 *   databaseUrl: process.env.DATABASE_URL!,
 * });
 * ```
 */

import { task } from "@trigger.dev/sdk/v3";
import { migrate, type MigrateOptions } from "./migrate.js";

export type { MigrateOptions, MigrationFile } from "./migrate.js";
export { getBundledAppNames, getBundledMigrations } from "./migrate.js";

/** Payload accepted by the `run-migrations` TriggerDev task. */
export interface MigrationPayload {
  /**
   * PostgreSQL connection URL.
   * Falls back to the `DATABASE_URL` environment variable if not provided.
   */
  databaseUrl?: string;
  /**
   * Module/app names to migrate.
   * Defaults to all bundled apps when omitted.
   * `_core` is always prepended automatically.
   */
  modules?: string[];
}

/**
 * Ready-to-use TriggerDev task that runs Semantius database migrations.
 *
 * Re-export this from your `trigger/` directory to deploy it without any
 * extra boilerplate:
 *
 * ```typescript
 * // trigger/migration.ts
 * export { migrationTask } from "@semantius/triggerdev";
 * ```
 */
export const migrationTask = task({
  id: "run-migrations",
  run: async (payload: MigrationPayload) => {
    const databaseUrl = payload.databaseUrl ?? process.env.DATABASE_URL;

    if (!databaseUrl) {
      throw new Error(
        "databaseUrl must be provided in the task payload or set as the DATABASE_URL environment variable",
      );
    }

    const options: MigrateOptions = { verbose: true };
    await migrate(databaseUrl, payload.modules, options);
  },
});
