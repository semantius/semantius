/**
 * Migrate command implementation (CLI).
 * Reads migration files from disk and delegates execution to @semantius/core,
 * whose header documents the run rules every runner shares.
 */

import { Client } from "@postgres";
import { join } from "@std/path";
import {
  type AppMigrations,
  FINAL_MIGRATION_NUMBER,
  getVersionsTableSql,
  isFinal,
  isMigrationCandidate,
  isOnce,
  migrationChecksum,
  type MigrationFile,
  migrationSql,
  orderMigrationNames,
  runMigrations,
} from "@semantius/core";
import { resolveAppDir, validateAppNames } from "../assets.ts";

/** Resolves `--apps` into the list to migrate, `_core` always first. */
function parseAppList(apps: string): string[] {
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
  validateAppNames(appList);
  return appList;
}

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
    const appList = parseAppList(apps);
    console.info(`Found ${appList.length} app(s) to process`);

    const toMigrate: AppMigrations[] = [];
    const missingApps: string[] = [];

    for (const app of appList) {
      const resolved = await resolveAppDir(app);
      if (!resolved) {
        console.log(`Not found: ${app}`);
        missingApps.push(app);
        continue;
      }
      toMigrate.push({
        app,
        migrations: await loadMigrationFiles(resolved.dir, app),
      });
    }

    // One connection for the whole run: the migration lock is a session lock,
    // and every file's ledger row must be read under it.
    await client.connect();
    console.info("Attempting to acquire global migration lock...");
    const result = await runMigrations(client, toMigrate);

    // Summary
    console.info("\nMigration Summary:");
    console.info(`Total apps processed: ${appList.length}`);
    console.info(`Existing apps found: ${toMigrate.length}`);
    console.info(`Missing apps: ${missingApps.length}`);
    console.info(
      `Files applied: ${result.applied}, skipped: ${result.skipped}`,
    );

    if (toMigrate.length > 0) {
      console.info(`\nFound apps: ${toMigrate.map((a) => a.app).join(", ")}`);
    }

    if (missingApps.length > 0) {
      console.info(`\nMissing apps: ${missingApps.join(", ")}`);
      console.info(
        "Make sure the app folders exist in the apps/ directory",
      );
    }

    console.info("Migrate command completed!");
  } catch (error) {
    console.error(
      "Migrate command failed:",
      describeConnectionError(error),
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

/** Turns the driver's connection errors into an actionable message. */
function describeConnectionError(error: unknown): string {
  if (!(error instanceof Error)) return String(error);
  const msg = error.message;
  if (msg.includes("authentication failed")) {
    return "Authentication failed. Check your username and password in DATABASE_URL.";
  }
  if (msg.includes("database") && msg.includes("does not exist")) {
    return "Database does not exist. Check the database name in DATABASE_URL.";
  }
  if (msg.includes("Connection refused")) {
    return "Connection refused. Database server may not be running or network issues.";
  }
  if (msg.includes("SSL")) {
    return "SSL connection error. Check SSL configuration in DATABASE_URL.";
  }
  return msg;
}

/** Migration text is normalized to LF before it reaches PostgreSQL. The .sql
 * files are CRLF in a Windows checkout and LF elsewhere, and a function body is
 * stored verbatim in pg_proc.prosrc - so without this, the same migration
 * installs a textually different database depending on who ran it. That is not
 * cosmetic: a character class or a quoted literal written across a line break
 * means one thing on one checkout and another on the next, and no test can see
 * the difference because each machine only ever builds one of them. Every
 * install path normalizes the same way, so all of them agree.
 */
function toLf(text: string): string {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

/**
 * Loads an app's migration files (`.sql`, `.once.sql`, `.jsonc`,
 * `.once.jsonc`) from {appDir}/migrations, LF-normalized, in run order. Other
 * files (a readme) are ignored; a misnamed migration or a duplicate number
 * throws. Shared with the extension builder so both see the same file set.
 */
export async function loadMigrationFiles(
  appDir: string,
  app: string,
): Promise<MigrationFile[]> {
  const dir = join(appDir, "migrations");
  const names: string[] = [];
  try {
    for await (const dirEntry of Deno.readDir(dir)) {
      if (dirEntry.isFile && isMigrationCandidate(dirEntry.name)) {
        names.push(dirEntry.name);
      }
    }
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      console.info(`No migrations folder found at: ${dir}`);
      return [];
    }
    throw error;
  }

  const migrations: MigrationFile[] = [];
  for (const name of orderMigrationNames(app, names)) {
    migrations.push({
      name,
      content: toLf(await Deno.readTextFile(join(dir, name))),
    });
  }
  return migrations;
}

/** The dollar tag quoting one migration inside an EXECUTE. */
export function migrationTag(m: { app: string; name: string }): string {
  return `$pgsem_${m.app.replace(/[^A-Za-z0-9_]/g, "_")}_${
    m.name.replace(/[^A-Za-z0-9_]/g, "_")
  }$`;
}

/** Quotes text as a SQL string literal. */
function sqlLiteral(text: string): string {
  return `'${text.replace(/'/g, "''")}'`;
}

/** Dollar tag of the DO block wrapping each file in script mode. */
const SCRIPT_TAG = "$pgsem_script$";

/**
 * Writes ./migrate.sql, a psql script that applies the same run rules as the
 * live runner: each file is a DO block that checks the file's `_versions` row
 * and checksum, runs the file through EXECUTE when due and records it, so each
 * file is its own transaction and the script can be run again. A session GUC
 * (`pgsem.ran`) carries "some file of this app ran" to the 9900 files.
 *
 * `\set ON_ERROR_STOP on` makes the first failure fatal. Unlike the live
 * runner, the 9900 files then do NOT run: psql has no way to continue past an
 * error to selected statements only. Rerun the script after fixing the cause;
 * the files that committed are skipped and the 9900 files follow.
 */
async function generateMigrationScript(apps: string): Promise<void> {
  console.log("Generating migration script...");

  const appList = parseAppList(apps);
  console.info(`Found ${appList.length} app(s) to process`);

  let scriptContent = "-- Generated migration script\n";
  scriptContent += "\\set ON_ERROR_STOP on\n\n";
  scriptContent +=
    "-- One migration at a time; the session lock is released when psql exits.\n";
  scriptContent += `DO ${SCRIPT_TAG}
BEGIN
  IF NOT pg_catalog.pg_try_advisory_lock(pg_catalog.hashtext('migrate')) THEN
    RAISE EXCEPTION 'another migration is running';
  END IF;
END
${SCRIPT_TAG};\n\n`;
  scriptContent += "-- Ensure _versions table exists\n";
  scriptContent += getVersionsTableSql();
  scriptContent += "\n\n";

  for (const app of appList) {
    console.log(`Processing: ${app}`);

    const resolved = await resolveAppDir(app);
    if (!resolved) {
      console.log(`Not found: ${app}`);
      continue;
    }

    const migrationFiles = await loadMigrationFiles(resolved.dir, app);

    if (migrationFiles.length === 0) {
      console.info(`No migration files found for ${app}`);
      continue;
    }

    console.info(`Found ${migrationFiles.length} migration file(s) for ${app}`);
    scriptContent += `-- App: ${app}\n`;
    scriptContent +=
      `SELECT pg_catalog.set_config('pgsem.ran', 'off', false);\n\n`;

    const ordered = [
      ...migrationFiles.filter((m) => !isFinal(m.name)),
      ...migrationFiles.filter((m) => isFinal(m.name)),
    ];

    for (const migration of ordered) {
      const versionName = `${app}.${migration.name}`;
      console.info(`  Adding ${versionName}`);

      if (!migration.content.trim()) {
        console.warn(`  Warning: Migration file ${migration.name} is empty`);
        continue;
      }

      const tag = migrationTag({ app, name: migration.name });
      const sql = migrationSql(migration);
      for (const t of [tag, SCRIPT_TAG]) {
        if (sql.includes(t)) {
          throw new Error(
            `Dollar tag ${t} occurs inside ${versionName}; it cannot be used to quote the file.`,
          );
        }
      }
      const checksum = await migrationChecksum(migration.content);
      const name = sqlLiteral(versionName);

      // The same decision as shouldRun() in @semantius/core.
      const due = isOnce(migration.name)
        ? `NOT EXISTS (SELECT 1 FROM public._versions WHERE name = ${name})`
        : `NOT EXISTS (SELECT 1 FROM public._versions WHERE name = ${name} AND checksum = '${checksum}')`;
      const condition = isFinal(migration.name)
        ? `pg_catalog.current_setting('pgsem.ran', true) = 'on'\n     OR ${due}`
        : due;

      scriptContent += `-- Migration: ${versionName}${
        isFinal(migration.name)
          ? ` (${FINAL_MIGRATION_NUMBER}+: also runs when another file of ${app} ran)`
          : ""
      }\n`;
      scriptContent += `DO ${SCRIPT_TAG}
BEGIN
  IF ${condition} THEN
    RAISE NOTICE 'applying %', ${name};
    PERFORM pg_catalog.set_config('pgsem.ran', 'on', false);
    EXECUTE ${tag}${sql}${sql.endsWith("\n") ? "" : "\n"}${tag};
    INSERT INTO public._versions (name, checksum) VALUES (${name}, '${checksum}')
      ON CONFLICT (name) DO UPDATE
      SET checksum = EXCLUDED.checksum, created_at = CURRENT_TIMESTAMP;
  END IF;
END
${SCRIPT_TAG};\n\n`;
    }
  }

  scriptContent += "SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtext('migrate'));\n\n";
  scriptContent += "-- Notify PostgREST to reload schema\n";
  scriptContent += "NOTIFY pgrst, 'reload schema';\n";

  const outputPath = "./migrate.sql";
  await Deno.writeTextFile(outputPath, scriptContent);

  console.log(`\nMigration script generated: ${outputPath}`);
  console.log("Script generation completed!");
}
