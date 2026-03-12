/**
 * Core migration logic (Node.js compatible).
 * This file mirrors packages/core/src/migrate.ts but uses only standard
 * TypeScript / Node.js APIs so it can be compiled with tsc.
 *
 * The shared logic (types, SQL templates, executeSQL, executeMigrations) is
 * duplicated here only to avoid a cross-runtime dependency.  Any changes to
 * the migration algorithm should be applied to both files.
 */

export interface MigrationFile {
  name: string;
  content: string;
}

export interface DatabaseClient {
  queryObject(
    sql: string,
    params?: unknown[],
  ): Promise<{ rows: Record<string, unknown>[] }>;
}

export function getVersionsTableSql(): string {
  return `CREATE TABLE IF NOT EXISTS _versions (
  name TEXT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_versions_name ON _versions(name);

ALTER TABLE _versions ENABLE ROW LEVEL SECURITY;`;
}

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
    console.info("[semantius/triggerdev] Created _versions table");
  }
}

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

export async function executeMigrations(
  appName: string,
  migrations: MigrationFile[],
  client: DatabaseClient,
): Promise<void> {
  console.info(
    `[semantius/triggerdev] Getting migration files for app: ${appName}`,
  );

  if (migrations.length === 0) {
    console.info(
      `[semantius/triggerdev] No migration files found for ${appName}`,
    );
    return;
  }

  console.info(
    `[semantius/triggerdev] Found ${migrations.length} migration file(s) for ${appName}:`,
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
      console.info(
        `  Skipping ${versionName} - already applied`,
      );
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
