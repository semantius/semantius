/**
 * Migrate command implementation (CLI).
 * Reads SQL files from disk and delegates execution to @semantius/core.
 */

import { Client } from "@postgres";
import {
  ensureVersionsTable,
  executeMigrations,
  getVersionsTableSql,
  type MigrationFile,
} from "@semantius/core";

export async function migrateCommand(
  apps: string,
  databaseUrl: string,
  scriptMode: boolean = false,
): Promise<void> {
  console.info("Starting migrate command...");

  // If in script mode, generate SQL file instead of executing
  if (scriptMode) {
    await generateMigrationScript(apps);
    return;
  }

  const client = new Client(databaseUrl);

  try {
    // Connect to the database to acquire global lock
    await client.connect();

    // Try to acquire advisory lock to prevent concurrent migrations
    console.info("Attempting to acquire global migration lock...");
    const lockResult = await client.queryObject(
      "SELECT pg_try_advisory_lock(hashtext('migrate'))",
    );
    const lockAcquired =
      (lockResult.rows[0] as { pg_try_advisory_lock: boolean })
        .pg_try_advisory_lock;

    if (!lockAcquired) {
      throw new Error(
        "Failed to acquire global migration lock. Another migration process may be running.",
      );
    }

    console.info("Global migration lock acquired");

    try {
      // If no apps provided or empty, default to just "_core"
      const appsToProcess = !apps || apps.trim() === "" ? "_core" : apps;

      // Add _core prefix if it doesn't start with "_core," and it's not just "_core"
      const processedAppsString =
        appsToProcess === "_core" || appsToProcess.startsWith("_core,")
          ? appsToProcess
          : `_core,${appsToProcess}`;
      console.info(`Processing apps parameter: ${appsToProcess}`);
      console.info(`Processed parameter: ${processedAppsString}`);

      // Split the comma-separated string and trim whitespace
      const appList = processedAppsString
        .split(",")
        .map((app) => app.trim())
        .filter((app) => app.length > 0);

      if (appList.length === 0) {
        console.error("No valid app names found");
        console.log("Provide comma-separated app names: app1,app2,app3");
        Deno.exit(1);
      }

      console.info(`Found ${appList.length} app(s) to process`);

      const processedApps: string[] = [];
      const existingApps: string[] = [];
      const missingApps: string[] = [];

      for (const app of appList) {
        processedApps.push(app);
        console.log(`Migrating: ${app}`);

        const appPath = `./apps/${app}`;
        try {
          const stat = await Deno.stat(appPath);
          if (stat.isDirectory) {
            await migrateApp(app, databaseUrl, app);
            console.info(`Migrated: ${app}`);
            existingApps.push(app);
          } else {
            console.log(`Path exists but is not a directory: ${app}`);
            missingApps.push(app);
          }
        } catch (error) {
          if (error instanceof Deno.errors.NotFound) {
            console.log(`Not found: ${app}`);
            missingApps.push(app);
          } else {
            throw error;
          }
        }
      }

      // Summary
      console.info("\nMigration Summary:");
      console.info(`Total apps processed: ${processedApps.length}`);
      console.info(`Existing apps found: ${existingApps.length}`);
      console.info(`Missing apps: ${missingApps.length}`);

      if (existingApps.length > 0) {
        console.info(`\nFound apps: ${existingApps.join(", ")}`);
      }

      if (missingApps.length > 0) {
        console.info(`\nMissing apps: ${missingApps.join(", ")}`);
        console.info(
          "Make sure the app folders exist in the apps/ directory",
        );
      }

      if (missingApps.length === 0) {
        console.info("\nAll specified apps found and ready for migration!");
      }

      console.info("Migrate command completed!");
    } finally {
      try {
        await client.queryObject(
          "SELECT pg_advisory_unlock(hashtext('migrate'))",
        );
        console.info("Global migration lock released");
      } catch (unlockError) {
        console.error(
          "Warning: Failed to release global migration lock:",
          unlockError instanceof Error
            ? unlockError.message
            : String(unlockError),
        );
      }
    }
  } catch (error) {
    console.error(
      "Migrate command failed:",
      error instanceof Error ? error.message : String(error),
    );
    Deno.exit(1);
  } finally {
    try {
      await client.end();
    } catch (_closeError) {
      console.warn("Warning: Could not close database connection properly");
    }
  }
}

async function migrateApp(
  appName: string,
  databaseUrl: string,
  folderName: string,
): Promise<void> {
  console.info(`Connecting to database for app: ${appName}`);

  const client = new Client(databaseUrl);

  try {
    await client.connect();
    console.info(`Database connection established for ${appName}`);

    // Ensure _versions table exists (shared core function)
    await ensureVersionsTable(client);

    // Load SQL files from disk
    const migrationFiles = await loadSqlFiles(folderName, "migrations");

    // Execute migrations using shared core function
    await executeMigrations(appName, migrationFiles, client);
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes("authentication failed")) {
        throw new Error(
          `Authentication failed for ${appName}. Check your username and password in DATABASE_URL.`,
        );
      } else if (
        error.message.includes("database") &&
        error.message.includes("does not exist")
      ) {
        throw new Error(
          `Database does not exist for ${appName}. Check the database name in DATABASE_URL.`,
        );
      } else if (error.message.includes("Connection refused")) {
        throw new Error(
          `Connection refused for ${appName}. Database server may not be running or network issues.`,
        );
      } else if (error.message.includes("SSL")) {
        throw new Error(
          `SSL connection error for ${appName}. Check SSL configuration in DATABASE_URL.`,
        );
      } else {
        throw new Error(
          `Database operation failed for ${appName}: ${error.message}`,
        );
      }
    } else {
      throw new Error(
        `Database operation failed for ${appName}: ${String(error)}`,
      );
    }
  } finally {
    try {
      await client.end();
      console.info(`Database connection closed for ${appName}`);
    } catch (_closeError) {
      console.warn(
        `Warning: Could not close database connection properly for ${appName}`,
      );
    }
  }
}

/** Loads all .sql files from apps/{folderName}/{subfolder}/ sorted ascending. */
async function loadSqlFiles(
  folderName: string,
  subfolder: string,
): Promise<MigrationFile[]> {
  const sqlPath = `./apps/${folderName}/${subfolder}`;

  try {
    const sqlFileNames: string[] = [];

    for await (const dirEntry of Deno.readDir(sqlPath)) {
      if (dirEntry.isFile && dirEntry.name.endsWith(".sql")) {
        sqlFileNames.push(dirEntry.name);
      }
    }

    sqlFileNames.sort();

    const migrations: MigrationFile[] = [];
    for (const fileName of sqlFileNames) {
      const filePath = `${sqlPath}/${fileName}`;
      const content = await Deno.readTextFile(filePath);
      migrations.push({
        name: fileName.replace(/\.sql$/, ""),
        content,
      });
    }

    return migrations;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      console.info(`No ${subfolder} folder found at: ${sqlPath}`);
      return [];
    } else {
      console.error(
        `Error reading ${subfolder} folder ${sqlPath}:`,
        error instanceof Error ? error.message : String(error),
      );
      return [];
    }
  }
}

async function generateMigrationScript(apps: string): Promise<void> {
  console.log("Generating migration script...");

  const appsToProcess = !apps || apps.trim() === "" ? "_core" : apps;

  const processedAppsString =
    appsToProcess === "_core" || appsToProcess.startsWith("_core,")
      ? appsToProcess
      : `_core,${appsToProcess}`;
  console.info(`Processing apps parameter: ${appsToProcess}`);
  console.info(`Processed parameter: ${processedAppsString}`);

  const appList = processedAppsString
    .split(",")
    .map((app) => app.trim())
    .filter((app) => app.length > 0);

  if (appList.length === 0) {
    console.error("No valid app names found");
    console.log("Provide comma-separated app names: app1,app2,app3");
    Deno.exit(1);
  }

  console.info(`Found ${appList.length} app(s) to process`);

  let scriptContent = "-- Generated migration script\n\n";
  scriptContent += "-- Ensure _versions table exists\n";
  scriptContent += getVersionsTableSql();
  scriptContent += "\n\n";

  for (const app of appList) {
    console.log(`Processing: ${app}`);

    const appPath = `./apps/${app}`;
    try {
      const stat = await Deno.stat(appPath);
      if (!stat.isDirectory) {
        console.log(`Path exists but is not a directory: ${app}`);
        continue;
      }
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        console.log(`Not found: ${app}`);
        continue;
      }
      throw error;
    }

    const migrationFiles = await loadSqlFiles(app, "migrations");

    if (migrationFiles.length === 0) {
      console.info(`No migration files found for ${app}`);
      continue;
    }

    console.info(`Found ${migrationFiles.length} migration file(s) for ${app}`);

    for (const migration of migrationFiles) {
      const versionName = `${app}.${migration.name}`;
      console.info(`  Adding ${versionName}`);

      if (!migration.content.trim()) {
        console.warn(`  Warning: Migration file ${migration.name} is empty`);
        continue;
      }

      scriptContent += `-- Migration: ${versionName}\n`;
      scriptContent += `BEGIN;\n\n`;
      scriptContent += migration.content;

      if (!migration.content.endsWith("\n")) {
        scriptContent += "\n";
      }
      scriptContent += "\n";

      scriptContent += `-- Record migration version\n`;
      scriptContent += `INSERT INTO public._versions (name) VALUES ('${versionName}');\n\n`;
      scriptContent += `COMMIT;\n\n`;
    }
  }

  scriptContent += "-- Notify PostgREST to reload schema\n";
  scriptContent += "NOTIFY pgrst, 'reload schema';\n";

  const outputPath = "./migrate.sql";
  await Deno.writeTextFile(outputPath, scriptContent);

  console.log(`\nMigration script generated: ${outputPath}`);
  console.log("Script generation completed!");
}
