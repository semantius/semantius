/**
 * Core migration logic shared between CLI and TriggerDev.
 * This module is runtime-agnostic (works with both Deno and Node.js)
 * via the DatabaseClient interface.
 *
 * Run rules, shared by every runner (this one, the CLI's script mode, the
 * extension's semantius.migrate() procedure and docker-postgres/initdb):
 *
 *   NNNN_name.sql, NNNN_name.jsonc
 *     repeatable: runs when `_versions` has no row for the file or the recorded
 *     value differs from the runner's. The file must therefore be safe to run
 *     again on a database that already has its objects (CREATE OR REPLACE,
 *     DROP ... IF EXISTS + CREATE, IF NOT EXISTS).
 *   NNNN_name.once.sql, NNNN_name.once.jsonc
 *     runs only when `_versions` has no row for it, never again, even when its
 *     text changes. Schema (tables, columns, seeds) lives here, because
 *     re-running a CREATE TABLE or an INSERT is not harmless.
 *   9900 and above
 *     runs last, and also whenever any other file of the app ran in this pass -
 *     including a pass in which a file failed. 9900_owner_hardening.sql hands
 *     every new object to semantius_owner; skipping it after a partial pass
 *     would leave the files that did commit owned by the installing superuser
 *     while their grants to semantius_user are already live.
 *
 * The recorded value (`_versions.checksum`) is `<ts>.<sha256>` for a core file
 * of a pg_semantius build and the plain SHA-256 of the text otherwise
 * (isStamped). Before the first file, runMigrations, the CLI's script mode and
 * semantius.migrate() refuse a database a newer build migrated, and one whose
 * `_core` run-once files were recorded with values other than their own
 * (checkCoreVersions). A run-once file
 * never runs again, so such a database never gets the schema this runner's
 * text creates, and the files after it would fail on what is missing.
 *
 * The ledger key is `<app>.<full file name>`, so a renamed file is a new file.
 * Clearing a row's checksum (`UPDATE _versions SET checksum = NULL`) forces a
 * repeatable file to run again; no check refuses a row without a checksum.
 */

/**
 * Represents a migration file with its name and content.
 * The name is the full file name, suffix included (`0010_core.sql`,
 * `0020_settings.once.sql`, `0300_audit_log.jsonc`): the suffix decides how the
 * file runs, and the name is the ledger key.
 */
export interface MigrationFile {
  name: string;
  content: string;
  /**
   * The value recorded in `_versions.checksum`. A core file of a pg_semantius
   * build records `<ts>.<sha256>` (see isStamped), which tells a later runner
   * which build last changed it. Without it, the runner records the plain
   * SHA-256 of the text.
   */
  version?: string;
}

/**
 * Runtime-agnostic database client interface.
 * Both Deno postgres and Node.js pg implement this shape.
 *
 * Every call must reach the SAME server session: the migration lock is a
 * session lock and each file is BEGIN / file / COMMIT on that session. A
 * pooled client that may hand each query to a different connection breaks
 * both.
 */
export interface DatabaseClient {
  queryObject(
    sql: string,
    params?: unknown[],
  ): Promise<{ rows: Record<string, unknown>[] }>;
}

/** Files numbered this high or higher run last and after every pass that ran anything. */
export const FINAL_MIGRATION_NUMBER = 9900;

/**
 * Dollar tag quoting the raw text of a `.jsonc` file. It must differ from
 * every tag the extension builder wraps a migration in, which is why it is not
 * `$pgsem_<app>_<name>$`; the builder refuses a migration containing any of
 * its tags, this one included.
 */
export const JSONC_TAG = "$pgsem_jsonc$";

/**
 * A migration file name: four-digit number, a name, an optional `.once`, and
 * `.sql` or `.jsonc`. Four digits exactly, so byte order is numeric order and
 * the 9900 files really do sort last.
 */
const MIGRATION_NAME = /^(\d{4})_[A-Za-z0-9_-]+(\.once)?\.(sql|jsonc)$/;

/** True for a file the loaders consider at all (anything else, e.g. readme.md, is ignored). */
export function isMigrationCandidate(fileName: string): boolean {
  return fileName.endsWith(".sql") || fileName.endsWith(".jsonc");
}

/** `.once.sql` / `.once.jsonc`: runs only when it has no ledger row. */
export function isOnce(fileName: string): boolean {
  return /\.once\.(sql|jsonc)$/.test(fileName);
}

/** `.jsonc`: an entity definition, applied through public.ensure_entities(). */
export function isJsonc(fileName: string): boolean {
  return fileName.endsWith(".jsonc");
}

/** The file's number (`0290_x.sql` -> 290). */
export function migrationNumber(fileName: string): number {
  const m = MIGRATION_NAME.exec(fileName);
  if (!m) throw new Error(`Not a migration file name: ${fileName}`);
  return Number(m[1]);
}

/** 9900 and above. */
export function isFinal(fileName: string): boolean {
  return migrationNumber(fileName) >= FINAL_MIGRATION_NUMBER;
}

/**
 * Byte order of two names. Not localeCompare: a locale may order `_` and
 * digits differently from the database's `ORDER BY name COLLATE "C"` and from
 * `LC_ALL=C` in the shell runner, and all runners must agree on the order.
 * The names are ASCII (MIGRATION_NAME), so UTF-16 code-unit order is byte
 * order.
 */
export function compareFileNames(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Validates an app's migration file names and returns them in run order.
 * Throws on a name that does not match the convention and on two files with
 * the same number: the number is what a reader uses to find a file's position,
 * and two files sharing one would run in an order nobody chose.
 */
export function orderMigrationNames(app: string, names: string[]): string[] {
  const seen = new Map<number, string>();
  for (const name of names) {
    if (!MIGRATION_NAME.test(name)) {
      throw new Error(
        `${app}: "${name}" is not a valid migration file name ` +
          `(expected NNNN_name.sql, NNNN_name.once.sql, NNNN_name.jsonc or ` +
          `NNNN_name.once.jsonc)`,
      );
    }
    const n = migrationNumber(name);
    const other = seen.get(n);
    if (other !== undefined) {
      throw new Error(
        `${app}: "${other}" and "${name}" share the number ${
          String(n).padStart(4, "0")
        }; migration numbers must be unique per app`,
      );
    }
    seen.set(n, name);
  }
  return [...names].sort(compareFileNames);
}

/**
 * The statement a `.jsonc` file runs as. The raw file text is passed to
 * PostgreSQL untouched and parsed there (public.jsonc_to_jsonb), so no runner
 * needs a JSONC parser and every runner produces the same call.
 */
export function wrapJsonc(text: string): string {
  if (text.includes(JSONC_TAG)) {
    throw new Error(
      `A .jsonc migration may not contain the text ${JSONC_TAG}: it quotes the file.`,
    );
  }
  return `SELECT public.ensure_entities(public.jsonc_to_jsonb(${JSONC_TAG}${text}${JSONC_TAG}));\n`;
}

/** The SQL a migration file executes: the file itself, or the wrapped `.jsonc`. */
export function migrationSql(file: MigrationFile): string {
  return isJsonc(file.name) ? wrapJsonc(file.content) : file.content;
}

/** A file's `_versions` row, or undefined when it has none. */
export interface LedgerRow {
  checksum: string | null;
}

/**
 * The ts of content no release has stamped yet. It sorts after every real ts,
 * so every released runner refuses a database that holds such content as
 * newer than itself, and that database has to be rebuilt.
 */
export const UNRELEASED_TS = "99999999999999";

/**
 * `<ts>.<sha256>`: the UTC time (YYYYMMDDHHMMSS) of the build that last
 * changed the file, and the SHA-256 of its text. Any other value, a bare
 * SHA-256 included, counts as plain: it says nothing about which build wrote
 * it.
 */
const STAMPED_VERSION = /^\d{14}\.[0-9a-f]{64}$/;

/** True for a stamped `<ts>.<sha256>` value. */
export function isStamped(value: string): boolean {
  return STAMPED_VERSION.test(value);
}

/** The ts of a stamped value; undefined for a plain one. */
export function versionTs(value: string): string | undefined {
  return isStamped(value) ? value.slice(0, 14) : undefined;
}

/**
 * The content part of a value: the hash of a stamped one, a plain one as it
 * is. Only a check of the text itself compares this part; the runners compare
 * whole values, so a changed ts alone counts as a change.
 */
export function versionHash(value: string): string {
  return isStamped(value) ? value.slice(15) : value;
}

/**
 * The latest ts among a runner's values, UNRELEASED_TS included; undefined
 * when none is stamped. ts values are 14 digits, so string order is time
 * order.
 */
export function latestTs(values: string[]): string | undefined {
  let latest: string | undefined;
  for (const value of values) {
    const ts = versionTs(value);
    if (ts !== undefined && (latest === undefined || ts > latest)) latest = ts;
  }
  return latest;
}

/** The ending every "replace" refusal shares, so a harness can match it. */
const REPLACE_ADVICE =
  "this database cannot be updated; replace the database with a fresh install";

/** The refusal of a database that a newer pg_semantius build has migrated. */
export function newerDatabaseMessage(
  file: string,
  ts: string,
  newest: string,
): string {
  return `_core in this database contains ${file} from a newer pg_semantius ` +
    `build (${ts}); this runner's newest is ${newest}; use a newer pg_semantius`;
}

/** The refusal of a run-once file the database recorded with another value. */
export function changedOnceMessage(file: string): string {
  return `run-once migration ${file} in this database differs from this ` +
    `version: ${REPLACE_ADVICE}`;
}

/** The refusal of a stamped row for a file this runner does not have. */
export function unknownFileMessage(file: string): string {
  return `migration ${file} in this database is not part of this version: ` +
    REPLACE_ADVICE;
}

/** A `_versions` row with its name, as the version checks read it. */
export interface LedgerEntry {
  name: string;
  checksum: string | null;
}

/**
 * The app the version checks cover. Only core files carry a build's ts; the
 * other apps are a project's own and record plain hashes.
 */
const CORE_APP = "_core";

/**
 * Decides whether this runner may update a database at all, from the
 * database's `_core.` rows and the runner's own `_core` files with their
 * values. Returns the refusal, or undefined.
 *
 * "Newer" comes first. A stamped row is newer when its ts is later than the
 * runner's ts for that file; when the runner does not have the file, or has
 * no ts for it, the row is compared with the runner's latest ts instead, so a
 * locally changed file cannot hide a newer database. Without this an older
 * runner re-applies its older text of every repeatable file, function by
 * function, and then fails on a schema it does not know, leaving a
 * half-downgraded database.
 *
 * "Replace" follows. A run-once file never runs again, so a database that
 * recorded one with a value other than the runner's never gets the schema
 * this runner's text creates. A plain row differs from every stamped value,
 * so a database whose run-once files were recorded without a ts is refused by
 * a runner that has one. A stamped row for a file the runner does not have
 * comes from a build this runner cannot place.
 *
 * Rows with a NULL checksum are never refused: clearing a checksum is how an
 * operator forces a repeatable file to run again.
 *
 * The extension's migrate() and the CLI's script mode run the same checks in
 * PL/pgSQL (versionCheckSql in packages/cli/commands/migrate.ts).
 */
export function checkCoreVersions(
  rows: LedgerEntry[],
  files: { name: string; value: string }[],
): string | undefined {
  const mine = new Map(files.map((f) => [f.name, f.value]));
  const newest = latestTs(files.map((f) => f.value));

  const core: { file: string; value: string }[] = [];
  for (const r of rows) {
    if (r.checksum === null || !r.name.startsWith(`${CORE_APP}.`)) continue;
    core.push({ file: r.name.slice(CORE_APP.length + 1), value: r.checksum });
  }
  core.sort((a, b) => compareFileNames(a.file, b.file));

  for (const { file, value } of core) {
    const ts = versionTs(value);
    if (ts === undefined) continue;
    const own = mine.get(file);
    const against = (own !== undefined ? versionTs(own) : undefined) ?? newest;
    if (against !== undefined && ts > against) {
      return newerDatabaseMessage(file, ts, newest ?? against);
    }
  }

  for (const { file, value } of core) {
    const own = mine.get(file);
    if (own === undefined) {
      if (isStamped(value)) return unknownFileMessage(file);
    } else if (isOnce(file) && value !== own) {
      return changedOnceMessage(file);
    }
  }
  return undefined;
}

/**
 * Whether a file runs, given its ledger row and whether any other file of the
 * same app ran (or failed) earlier in this pass. The 9900 rule is checked
 * before the `.once.` rule on purpose: a finalizer's job is to follow whatever
 * ran, whatever its suffix.
 */
export function shouldRun(
  file: { name: string; checksum: string },
  row: LedgerRow | undefined,
  ranInPass: boolean,
): boolean {
  if (!row) return true;
  if (isFinal(file.name) && ranInPass) return true;
  if (isOnce(file.name)) return false;
  return row.checksum !== file.checksum;
}

/** Returns the SQL to create the _versions tracking table. */
export function getVersionsTableSql(): string {
  // `checksum` is the applied migration's version value: `<ts>.<sha256>` for a
  // core file of a pg_semantius build, otherwise the SHA-256 of the
  // LF-normalized text (see isStamped). Every runner writes it and every
  // runner compares against it as a whole string: a repeatable file runs
  // again when it differs, and semantius.status() lists a `.once.` file whose
  // value changed after it was applied. ADD COLUMN IF NOT EXISTS
  // keeps the statement idempotent for databases created before the column
  // existed. The primary key on name is the table's only index and serves every
  // lookup by file name.
  return `CREATE TABLE IF NOT EXISTS _versions (
  name TEXT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

ALTER TABLE _versions ADD COLUMN IF NOT EXISTS checksum TEXT;

ALTER TABLE _versions ENABLE ROW LEVEL SECURITY;`;
}

/**
 * Records a file as applied with its checksum. An upsert because a repeatable
 * file already has a row when it runs again; `created_at` then records when
 * the current text was applied.
 */
export const LEDGER_UPSERT_SQL =
  `INSERT INTO public._versions (name, checksum) VALUES ($1, $2)
ON CONFLICT (name) DO UPDATE
  SET checksum = EXCLUDED.checksum, created_at = CURRENT_TIMESTAMP`;

/**
 * SHA-256 of the LF-normalized text: the plain value written into
 * `_versions.checksum`, and the hash part of a stamped one.
 */
export async function migrationChecksum(content: string): Promise<string> {
  const normalized = content.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(normalized),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Ensures the _versions table exists and is up to date.
 *
 * The DDL runs unconditionally: every statement in it is idempotent, and a
 * database created before `checksum` existed needs the ALTER to run too, or
 * the INSERT below would fail on the missing column.
 */
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

  await client.queryObject(getVersionsTableSql());
  if (!exists) console.info("Created _versions table");
}

/**
 * Takes the migration lock for this session, or fails at once.
 *
 * A SESSION lock, not pg_advisory_xact_lock: every file commits on its own, and
 * a transaction lock would be released by the first COMMIT. The extension's
 * semantius.migrate() takes the same key, so the CLI, the procedure and the
 * provisioners exclude each other. Failing rather than waiting: a second run
 * queued behind the first would only find nothing left to do, or run against a
 * half-finished first pass that then fails.
 */
export async function acquireMigrationLock(
  client: DatabaseClient,
): Promise<void> {
  const result = await client.queryObject(
    "SELECT pg_try_advisory_lock(hashtext('migrate')) AS acquired",
  );
  if (!(result.rows[0] as { acquired: boolean }).acquired) {
    throw new Error("another migration is running");
  }
}

/** Releases the lock taken by acquireMigrationLock(). Never throws. */
export async function releaseMigrationLock(
  client: DatabaseClient,
): Promise<void> {
  try {
    await client.queryObject("SELECT pg_advisory_unlock(hashtext('migrate'))");
  } catch (unlockError) {
    console.error(
      "Warning: Failed to release the migration lock:",
      unlockError instanceof Error ? unlockError.message : String(unlockError),
    );
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

/** Counts reported by executeMigrations(). */
export interface MigrationResult {
  applied: number;
  skipped: number;
}

/** Runs one file in its own transaction and records it. */
async function applyMigration(
  client: DatabaseClient,
  appName: string,
  migration: MigrationFile,
  checksum: string,
): Promise<void> {
  const versionName = `${appName}.${migration.name}`;
  console.info(`  Executing migration: ${versionName}`);

  await client.queryObject("BEGIN");
  try {
    if (!migration.content.trim()) {
      throw new Error(
        `Migration file ${migration.name} is empty or contains only whitespace`,
      );
    }

    await executeSQL(client, migrationSql(migration), migration.name);
    await client.queryObject(LEDGER_UPSERT_SQL, [versionName, checksum]);

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

/**
 * Executes an app's migration files by the run rules above. Each file runs in
 * its own transaction and is recorded on success.
 *
 * The caller must hold the migration lock on this same client (see
 * runMigrations): the ledger rows are read here, file by file, and a row read
 * without the lock may be stale by the time the file runs.
 *
 * On a failing file the remaining ordinary files are skipped, the 9900 files
 * still run (each in its own transaction), and then the original error is
 * thrown. A failure inside a 9900 file is reported next to it.
 */
export async function executeMigrations(
  appName: string,
  migrations: MigrationFile[],
  client: DatabaseClient,
): Promise<MigrationResult> {
  console.info(`Getting migration files for app: ${appName}`);

  if (migrations.length === 0) {
    console.info(`No migration files found for ${appName}`);
    return { applied: 0, skipped: 0 };
  }

  const byName = new Map(migrations.map((m) => [m.name, m]));
  const ordered = orderMigrationNames(appName, [...byName.keys()])
    .map((n) => byName.get(n)!);

  console.info(
    `Found ${ordered.length} migration file(s) for ${appName}:`,
  );

  const result: MigrationResult = { applied: 0, skipped: 0 };
  let ranInPass = false;
  let failure: unknown = undefined;

  const step = async (migration: MigrationFile): Promise<void> => {
    console.info(`  ${migration.name}`);
    const versionName = `${appName}.${migration.name}`;
    const checksum = migration.version ??
      await migrationChecksum(migration.content);

    const ledger = await client.queryObject(
      `SELECT checksum FROM public._versions WHERE name = $1`,
      [versionName],
    );
    const row = ledger.rows[0] as unknown as LedgerRow | undefined;

    if (!shouldRun({ name: migration.name, checksum }, row, ranInPass)) {
      console.info(
        `  Skipping ${versionName} - ${
          row && row.checksum !== checksum ? "run once, changed since" : "unchanged"
        }`,
      );
      result.skipped++;
      return;
    }

    ranInPass = true;
    try {
      await applyMigration(client, appName, migration, checksum);
      result.applied++;
    } catch (error) {
      if (failure === undefined) {
        failure = error;
      } else {
        console.error(
          `  ${versionName} also failed after the earlier failure: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
    }
  };

  for (const migration of ordered.filter((m) => !isFinal(m.name))) {
    await step(migration);
    if (failure !== undefined) break;
  }
  if (failure !== undefined) {
    console.error(
      `  ${appName}: a migration failed; running the ${FINAL_MIGRATION_NUMBER}+ files before reporting it`,
    );
  }
  for (const migration of ordered.filter((m) => isFinal(m.name))) {
    await step(migration);
  }

  if (failure !== undefined) throw failure;
  return result;
}

/** One app's files, in the order the apps are migrated. */
export interface AppMigrations {
  app: string;
  migrations: MigrationFile[];
}

/**
 * Adds the required checks fields do not have yet, one table per transaction, so
 * that locks never pile up across tables on a live database. See
 * dd_install_missing_checks in 0180_managed_enable.sql. Whatever it skips is
 * picked up by a later run, so a skip is reported and does not fail this one.
 */
async function installMissingChecks(client: DatabaseClient): Promise<void> {
  const present = await client.queryObject(
    `SELECT to_regprocedure('public.dd_install_missing_checks(text)') IS NOT NULL AS present`,
  );
  if (!(present.rows[0] as { present: boolean }).present) return;

  let after: string | null = null;
  while (true) {
    const res = await client.queryObject(
      `SELECT p_table, p_skipped FROM public.dd_install_missing_checks($1)`,
      [after],
    );
    const row = res.rows[0] as {
      p_table: string | null;
      p_skipped: { table: string; field?: string; reason: string }[];
    };
    for (const s of row.p_skipped) {
      console.warn(
        `  Not enforced yet: ${s.table}${s.field ? `.${s.field}` : ""}: ${s.reason}`,
      );
    }
    if (row.p_table === null) return;
    after = row.p_table;
  }
}

/** The rows checkCoreVersions() decides from. */
const CORE_ROWS_SQL =
  `SELECT name, checksum FROM public._versions WHERE pg_catalog.starts_with(name, '${CORE_APP}.')`;

/**
 * Throws checkCoreVersions()'s refusal, with the runner's `_core` files valued
 * as executeMigrations() records them. Runs under the lock, so no other runner
 * can change the rows between this read and the first file.
 */
async function refuseUnsafeUpdate(
  client: DatabaseClient,
  apps: AppMigrations[],
): Promise<void> {
  const core = apps.find((a) => a.app === CORE_APP)?.migrations ?? [];
  const files: { name: string; value: string }[] = [];
  for (const m of core) {
    files.push({
      name: m.name,
      value: m.version ?? await migrationChecksum(m.content),
    });
  }
  const rows = (await client.queryObject(CORE_ROWS_SQL)).rows as unknown as
    LedgerEntry[];
  const refusal = checkCoreVersions(rows, files);
  if (refusal !== undefined) throw new Error(refusal);
}

/**
 * The whole run: takes the migration lock once, ensures the ledger exists,
 * refuses a database this runner must not update (checkCoreVersions), migrates
 * each app in order on this one client, adds the missing required checks, and
 * releases the lock on every path. A refusal comes before the first file, so
 * it changes nothing. A failure stops the run after the failing app's 9900
 * files.
 */
export async function runMigrations(
  client: DatabaseClient,
  apps: AppMigrations[],
): Promise<MigrationResult> {
  await acquireMigrationLock(client);
  try {
    await ensureVersionsTable(client);
    await refuseUnsafeUpdate(client, apps);
    const total: MigrationResult = { applied: 0, skipped: 0 };
    for (const { app, migrations } of apps) {
      const r = await executeMigrations(app, migrations, client);
      total.applied += r.applied;
      total.skipped += r.skipped;
    }
    await installMissingChecks(client);
    return total;
  } finally {
    await releaseMigrationLock(client);
  }
}
