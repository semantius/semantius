/**
 * @semantius/triggerdev
 *
 * TriggerDev integration for Semantius Core.
 * Run database migrations from TriggerDev tasks using pre-bundled SQL content.
 *
 * @example
 * ```typescript
 * import { task } from "@trigger.dev/sdk/v3";
 * import { migrate } from "@semantius/triggerdev";
 *
 * export const migrationTask = task({
 *   id: "run-migrations",
 *   run: async (payload: { modules?: string[] }) => {
 *     await migrate(process.env.DATABASE_URL!, payload.modules);
 *   },
 * });
 * ```
 */

export {
  migrate,
  type MigrateOptions,
  getBundledAppNames,
  getBundledMigrations,
  type MigrationFile,
} from "./migrate.js";
