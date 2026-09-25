/**
 * @semantius/core - Shared core logic for Semantius CLI and TriggerDev
 */

export {
  acquireMigrationLock,
  type AppMigrations,
  compareFileNames,
  type DatabaseClient,
  ensureVersionsTable,
  executeMigrations,
  executeSQL,
  FINAL_MIGRATION_NUMBER,
  getVersionsTableSql,
  isFinal,
  isJsonc,
  isMigrationCandidate,
  isOnce,
  JSONC_TAG,
  LEDGER_UPSERT_SQL,
  type LedgerRow,
  migrationChecksum,
  migrationNumber,
  migrationSql,
  type MigrationFile,
  type MigrationResult,
  orderMigrationNames,
  releaseMigrationLock,
  runMigrations,
  shouldRun,
  wrapJsonc,
} from "./migrate.ts";
