/**
 * Migrate command implementation (CLI).
 * Reads migration files from disk and delegates execution to @semantius/core,
 * whose header documents the run rules every runner shares.
 */

import { Client } from "@postgres";
import { join } from "@std/path";
import {
  type AppMigrations,
  changedOnceMessage,
  FINAL_MIGRATION_NUMBER,
  getVersionsTableSql,
  isFinal,
  isMigrationCandidate,
  isOnce,
  isStamped,
  latestTs,
  migrationChecksum,
  type MigrationFile,
  migrationSql,
  newerDatabaseMessage,
  orderMigrationNames,
  runMigrations,
  unknownFileMessage,
  versionHash,
} from "@semantius/core";
import {
  type AppsSource,
  resolveAppDir,
  validateAppNames,
} from "../assets.ts";
import { RUNNING_UNDER_DENO } from "../invocation.ts";
// extension.ts imports this module as well. The cycle is harmless: neither
// module calls into the other while it loads.
import { compareVersions } from "./extension.ts";

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

/** This CLI's build manifest, as a refusal names it. */
const MANIFEST = "extension/versions.json";

/**
 * The files of the highest version in a build manifest, `<app>/<name>` to
 * value. Throws, naming the manifest, when it records no version or is not
 * shaped like one: without its values the CLI would record plain hashes for
 * every core file, and a released runner refuses to update a database whose
 * run-once files were recorded that way.
 */
export function manifestFiles(raw: unknown): Record<string, string> {
  const unreadable = (why: string) =>
    new Error(`cannot read the version manifest ${MANIFEST}: ${why}`);
  const versions = typeof raw === "object" && raw !== null
    ? (raw as { versions?: unknown }).versions
    : undefined;
  if (typeof versions !== "object" || versions === null) {
    throw unreadable("it has no versions");
  }
  const names = Object.keys(versions).sort(compareVersions);
  const highest = names[names.length - 1];
  if (highest === undefined) throw unreadable("it records no version");
  const files = (versions as Record<string, { files?: unknown } | null>)[
    highest
  ]?.files;
  if (
    typeof files !== "object" || files === null ||
    Object.values(files).some((v) => typeof v !== "string")
  ) {
    throw unreadable(`version ${highest} has no file list`);
  }
  return files as Record<string, string>;
}

/**
 * The value a migration records in `_versions.checksum`. A `_core` file takes
 * the build's stamped value when the build holds that very text. Everything
 * else takes the plain hash: nwind and test are not versioned with the build,
 * and a `_core` file the build does not hold, or holds with other text, is
 * part of no build a later runner could place.
 */
export function migrationVersion(
  files: Record<string, string>,
  app: string,
  name: string,
  hash: string,
): string {
  if (app !== "_core") return hash;
  const value = files[`${app}/${name}`];
  return value !== undefined && versionHash(value) === hash ? value : hash;
}

/**
 * Reads this CLI's manifest. A dynamic import with a literal path: the literal
 * is what makes `deno compile` embed the file, and the import runs only here,
 * so the extension generator, which imports this module, still runs before
 * the manifest exists.
 */
async function readManifestFiles(): Promise<Record<string, string>> {
  let raw: unknown;
  try {
    raw = (await import("../../../extension/versions.json", {
      with: { type: "json" },
    })).default;
  } catch (error) {
    throw new Error(
      `cannot read the version manifest ${MANIFEST}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
  return manifestFiles(raw);
}

/**
 * The manifest's files, or exit 1 before anything runs. reset and retest call
 * it before they drop anything, so a build that cannot read its manifest
 * leaves the database as it was.
 */
export async function requireManifestFiles(): Promise<Record<string, string>> {
  try {
    return await readManifestFiles();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}

/** A migration file with the value it records. */
type VersionedFile = MigrationFile & { version: string };

/** An app as migrate found it: where it came from and its files. */
interface LoadedApp {
  app: string;
  dir: string;
  source: AppsSource;
  migrations: VersionedFile[];
}

/**
 * Resolves and loads every app, each file with its value from the manifest.
 * The manifest is read first, so an unreadable one refuses before any file is
 * read or any connection opened.
 */
async function loadApps(
  appList: string[],
): Promise<{ loaded: LoadedApp[]; missing: string[] }> {
  const files = await requireManifestFiles();
  const loaded: LoadedApp[] = [];
  const missing: string[] = [];
  for (const app of appList) {
    const resolved = await resolveAppDir(app);
    if (!resolved) {
      console.log(`Not found: ${app}`);
      missing.push(app);
      continue;
    }
    const migrations: VersionedFile[] = [];
    for (const m of await loadMigrationFiles(resolved.dir, app)) {
      const hash = await migrationChecksum(m.content);
      migrations.push({
        ...m,
        version: migrationVersion(files, app, m.name, hash),
      });
    }
    loaded.push({
      app,
      dir: resolved.dir,
      source: resolved.source,
      migrations,
    });
  }
  return { loaded, missing };
}

/**
 * Whether `migrate` asks before it applies a `_core` taken from the working
 * directory. A core file without a ts is recorded with its plain hash, and a
 * released runner refuses to update a database that recorded one of its
 * run-once files that way. UNRELEASED_TS counts as a ts. Only the compiled
 * binary asks: a run from a checkout is a development build. `confirm` skips
 * the question: `--confirm`, and reset and retest, which rebuild the database.
 */
export function asksBeforeLocalCore(input: {
  underDeno: boolean;
  confirm: boolean;
  source: AppsSource;
  versions: string[];
}): boolean {
  return !input.underDeno && !input.confirm && input.source === "cwd" &&
    input.versions.some((v) => !isStamped(v));
}

/**
 * The answer that applies the local `_core` anyway: exactly `Y`, as dropall
 * asks. `prompt()` answers null without a terminal, which refuses.
 */
export function acceptsLocalCore(answer: string | null): boolean {
  return answer === "Y";
}

/**
 * Asks before a `_core` from the working directory is applied, or exits 1. It
 * runs before any connection is opened, so no lock is held while someone
 * types.
 */
function confirmLocalCore(loaded: LoadedApp[], confirm: boolean): void {
  const core = loaded.find((a) => a.app === "_core");
  if (!core) return;
  const ask = asksBeforeLocalCore({
    underDeno: RUNNING_UNDER_DENO,
    confirm,
    source: core.source,
    versions: core.migrations.map((m) => m.version),
  });
  if (!ask) return;
  const plain = core.migrations.filter((m) => !isStamped(m.version));
  console.warn(
    `_core is taken from ${core.dir}, and ${plain.length} of its file(s) ` +
      `are not part of this pg_semantius build:`,
  );
  for (const m of plain) console.warn(`  ${m.name}`);
  console.warn(
    "They are recorded with a plain hash. A released pg_semantius refuses to " +
      "update a database that recorded one of its run-once files that way.",
  );
  if (!acceptsLocalCore(prompt("Type 'Y' to apply it anyway:"))) {
    console.error(
      "Not applied. Pass --confirm to apply it without this question.",
    );
    Deno.exit(1);
  }
}

export async function migrateCommand(
  apps: string,
  databaseUrl: string,
  scriptMode: boolean = false,
  confirm: boolean = false,
): Promise<void> {
  console.info("Starting migrate command...");

  // If in script mode, generate SQL file instead of executing
  if (scriptMode) {
    await generateMigrationScript(apps, confirm);
    return;
  }

  const client = new Client(databaseUrl);

  try {
    const appList = parseAppList(apps);
    console.info(`Found ${appList.length} app(s) to process`);

    const { loaded, missing: missingApps } = await loadApps(appList);
    confirmLocalCore(loaded, confirm);
    const toMigrate: AppMigrations[] = loaded.map((a) => ({
      app: a.app,
      migrations: a.migrations,
    }));

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
 * A stamped value (isStamped in @semantius/core) as a SQL regular expression.
 * No backslash, so it reads the same whatever standard_conforming_strings
 * says.
 */
const STAMPED_SQL = "'^[0-9]{14}[.][0-9a-f]{64}$'";

/**
 * A PL/pgSQL block (DECLARE ... END, without the closing semicolon) that runs
 * checkCoreVersions() of @semantius/core against public._versions: "newer"
 * first, then "replace", each raised with SQLSTATE 55000 and the CLI's
 * message. A client prints only the message, so it carries the remedy.
 *
 * `files` are the runner's `_core` files with the values it records.
 * `unlock` releases the migration lock before each RAISE; script mode needs
 * it, while the extension's migrate() runs the block inside a handler that
 * releases the lock. `newerAdvice` is appended to the "newer" message.
 */
export function versionCheckSql(
  files: { name: string; value: string; once: boolean }[],
  opts: { unlock: boolean; newerAdvice?: string },
): string {
  const core = Object.fromEntries(
    files.map((f) => [f.name, { value: f.value, once: f.once }]),
  );
  const newest = latestTs(files.map((f) => f.value));
  const raise = (indent: string, message: string, args: string) =>
    (opts.unlock
      ? "PERFORM pg_catalog.pg_advisory_unlock(pg_catalog.hashtext('migrate'));\n" +
        indent
      : "") +
    `RAISE EXCEPTION ${sqlLiteral(message)}, ${args}\n` +
    `${indent}  USING ERRCODE = '55000';`;
  return `DECLARE
  v_core   jsonb := ${sqlLiteral(JSON.stringify(core))}::jsonb;
  v_newest text := ${newest === undefined ? "NULL" : sqlLiteral(newest)};
  v_row    record;
  v_file   text;
  v_entry  jsonb;
  v_mine   text;
BEGIN
  -- Newer: a stamped row later than this runner's ts for that file, or than
  -- its newest ts when it has no ts for the file.
  FOR v_row IN
    SELECT v.name, v.checksum FROM public._versions v
     WHERE pg_catalog.starts_with(v.name, '_core.')
       AND v.checksum ~ ${STAMPED_SQL}
     ORDER BY v.name COLLATE "C"
  LOOP
    v_file := pg_catalog.substr(v_row.name, 7);
    v_mine := v_core -> v_file ->> 'value';
    v_mine := CASE WHEN v_mine ~ ${STAMPED_SQL}
                   THEN pg_catalog.left(v_mine, 14) ELSE v_newest END;
    IF pg_catalog.left(v_row.checksum, 14) COLLATE "C" > v_mine THEN
      ${
    raise(
      "      ",
      newerDatabaseMessage("%", "%", "%") + (opts.newerAdvice ?? ""),
      "v_file, pg_catalog.left(v_row.checksum, 14), v_newest",
    )
  }
    END IF;
  END LOOP;
  -- Replace: a run-once row whose value differs from this runner's, and a
  -- stamped row for a file this runner does not have. NULL rows pass.
  FOR v_row IN
    SELECT v.name, v.checksum FROM public._versions v
     WHERE pg_catalog.starts_with(v.name, '_core.')
       AND v.checksum IS NOT NULL
     ORDER BY v.name COLLATE "C"
  LOOP
    v_file := pg_catalog.substr(v_row.name, 7);
    v_entry := v_core -> v_file;
    IF v_entry IS NULL THEN
      IF v_row.checksum ~ ${STAMPED_SQL} THEN
        ${raise("        ", unknownFileMessage("%"), "v_file")}
      END IF;
    ELSIF (v_entry ->> 'once')::boolean
          AND v_row.checksum IS DISTINCT FROM v_entry ->> 'value' THEN
      ${raise("      ", changedOnceMessage("%"), "v_file")}
    END IF;
  END LOOP;
END`;
}

/**
 * Writes ./migrate.sql, a psql script that applies the same run rules as the
 * live runner: each file is a DO block that checks the file's `_versions` row
 * and recorded value, runs the file through EXECUTE when due and records it, so each
 * file is its own transaction and the script can be run again. A session GUC
 * (`pgsem.ran`) carries "some file of this app ran" to the 9900 files. Before
 * the first file, a DO block refuses a database this build must not update
 * (versionCheckSql), so a refusal changes nothing.
 *
 * `\set ON_ERROR_STOP on` makes the first failure fatal. Unlike the live
 * runner, the 9900 files then do NOT run: psql has no way to continue past an
 * error to selected statements only. Rerun the script after fixing the cause;
 * the files that committed are skipped and the 9900 files follow.
 */
async function generateMigrationScript(
  apps: string,
  confirm: boolean,
): Promise<void> {
  console.log("Generating migration script...");

  const appList = parseAppList(apps);
  console.info(`Found ${appList.length} app(s) to process`);

  const { loaded } = await loadApps(appList);
  confirmLocalCore(loaded, confirm);

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

  // The files the script writes, so the check judges the database against
  // exactly what this script would run: an empty file is left out of both.
  const coreFiles = (loaded.find((a) => a.app === "_core")?.migrations ?? [])
    .filter((m) => m.content.trim())
    .map((m) => ({ name: m.name, value: m.version, once: isOnce(m.name) }));
  scriptContent +=
    "-- Refuse a database this build must not update, before the first file.\n";
  scriptContent += `DO ${SCRIPT_TAG}\n${
    versionCheckSql(coreFiles, { unlock: true })
  }\n${SCRIPT_TAG};\n\n`;

  for (const { app, migrations: migrationFiles } of loaded) {
    console.log(`Processing: ${app}`);

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
      const checksum = migration.version;
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
