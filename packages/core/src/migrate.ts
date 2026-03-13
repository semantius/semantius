/**
 * Core migration logic shared between CLI and TriggerDev.
 * This module is runtime-agnostic (works with both Deno and Node.js)
 * via the DatabaseClient interface.
 */

/**
 * Represents a SQL migration file with its name and content.
 * The name should be the filename without the .sql extension.
 */
export interface MigrationFile {
  name: string;
  content: string;
}

/**
 * Runtime-agnostic database client interface.
 * Both Deno postgres and Node.js pg implement this shape.
 */
export interface DatabaseClient {
  queryObject(
    sql: string,
    params?: unknown[],
  ): Promise<{ rows: Record<string, unknown>[] }>;
}

/** Returns the SQL to create the _versions tracking table. */
export function getVersionsTableSql(): string {
  return `CREATE TABLE IF NOT EXISTS _versions (
  name TEXT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_versions_name ON _versions(name);

ALTER TABLE _versions ENABLE ROW LEVEL SECURITY;`;
}

/** Ensures the _versions table exists, creating it if needed. */
export async function ensureVersionsTable(
  client: DatabaseClient,
): Promise<void> {
  const checkTableQuery = `
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_name = '_versions'
    );
  `;

  const tableExists = await client.queryObject(checkTableQuery);
  const exists = (tableExists.rows[0] as { exists: boolean }).exists;

  if (!exists) {
    await client.queryObject(getVersionsTableSql());
    console.info("Created _versions table");
  }
}

/**
 * Executes a SQL string against the database client.
 * Provides detailed PostgreSQL error reporting on failure.
 */
export async function executeSQL(
  client: DatabaseClient,
  sqlContent: string,
  fileName: string,
): Promise<void> {
  try {
    await client.queryObject(sqlContent);
  } catch (sqlError) {
    console.error(`\n=== SQL Error in ${fileName} ===`);

    if (sqlError instanceof Error) {
      console.error(`Message: ${sqlError.message}`);

      const postgresError = sqlError as Error & {
        fields?: {
          severity?: string;
          code?: string;
          message?: string;
          position?: string;
          detail?: string;
          hint?: string;
          where?: string;
          file?: string;
          line?: string;
          routine?: string;
        };
      };

      if (postgresError.fields) {
        const fields = postgresError.fields;
        if (fields.severity) console.error(`Severity: ${fields.severity}`);
        if (fields.code) console.error(`Code: ${fields.code}`);
        if (fields.detail) console.error(`Detail: ${fields.detail}`);
        if (fields.hint) console.error(`Hint: ${fields.hint}`);
        if (fields.where) console.error(`Where: ${fields.where}`);
        if (fields.position) console.error(`Position: ${fields.position}`);

        let errorLine = "";
        if (fields.position) {
          const position = parseInt(fields.position) - 1;
          const lines = sqlContent.split("\n");
          let charCount = 0;
          let lineNumber = 1;

          for (const line of lines) {
            if (position >= charCount && position < charCount + line.length) {
              errorLine = `LINE ${lineNumber}: ${line}`;
              console.error(errorLine);
              break;
            }
            charCount += line.length + 1;
            lineNumber++;
          }
        }

        console.error(`=== End SQL Error ===\n`);

        const errorMsg = errorLine
          ? `SQL execution failed in ${fileName}: ${sqlError.message}\n${errorLine}`
          : `SQL execution failed in ${fileName}: ${sqlError.message}`;
        throw new Error(errorMsg);
      }
    }

    throw sqlError;
  }
}

/**
 * Executes a list of migration files against the database, skipping any
 * that have already been recorded in the _versions table.
 * Each migration runs inside a transaction and is recorded on success.
 */
export async function executeMigrations(
  appName: string,
  migrations: MigrationFile[],
  client: DatabaseClient,
): Promise<void> {
  console.info(`Getting migration files for app: ${appName}`);

  if (migrations.length === 0) {
    console.info(`No migration files found for ${appName}`);
    return;
  }

  console.info(
    `Found ${migrations.length} migration file(s) for ${appName}:`,
  );

  for (const migration of migrations) {
    console.info(`  ${migration.name}`);

    const versionName = `${appName}.${migration.name}`;

    const checkVersionQuery = `
      SELECT EXISTS (
        SELECT 1 FROM _versions
        WHERE name = $1
      );
    `;

    const versionResult = await client.queryObject(checkVersionQuery, [
      versionName,
    ]);
    const versionExists = (versionResult.rows[0] as { exists: boolean }).exists;

    if (versionExists) {
      console.info(`  Skipping ${versionName} - already applied`);
      continue;
    }

    console.info(`  Executing migration: ${versionName}`);

    await client.queryObject("BEGIN");

    try {
      if (!migration.content.trim()) {
        throw new Error(
          `Migration file ${migration.name} is empty or contains only whitespace`,
        );
      }

      await executeSQL(client, migration.content, migration.name);

      await client.queryObject(
        `INSERT INTO public._versions (name) VALUES ($1)`,
        [versionName],
      );

      // Notify PostgREST (if present) to reload its schema cache so the
      // new objects are immediately accessible via the REST API.
      // Safe to fire even when PostgREST is not running.
      await client.queryObject("NOTIFY pgrst, 'reload schema'");
      await client.queryObject("COMMIT");

      console.info(`  Migration ${versionName} completed and recorded`);
    } catch (error) {
      try {
        await client.queryObject("ROLLBACK");
      } catch (rollbackError) {
        console.error(
          `Warning: Failed to rollback transaction for ${migration.name}:`,
          rollbackError instanceof Error
            ? rollbackError.message
            : String(rollbackError),
        );
      }
      throw error;
    }
  }
}
