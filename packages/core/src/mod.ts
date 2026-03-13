/**
 * @semantius/core - Shared core logic for Semantius CLI and TriggerDev
 */

export {
  type DatabaseClient,
  ensureVersionsTable,
  executeSQL,
  executeMigrations,
  getVersionsTableSql,
  type MigrationFile,
} from "./migrate.ts";
