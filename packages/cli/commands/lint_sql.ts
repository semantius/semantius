/**
 * `lint-sql`: plpgsql_check over every PL/pgSQL function in an installed
 * Semantius database, including the trigger functions a bare invocation cannot
 * reach (Q6).
 *
 * plpgsql_check refuses a trigger function without `relid` ("missing trigger
 * relation"), and a statement-level trigger function whose body reads its
 * transition tables reports `relation "new_rows" does not exist` unless it is
 * told the names the trigger's REFERENCING clause declares. Both are things a
 * bound trigger already knows, so they are read back out of pg_trigger rather
 * than guessed: `relid` from the relation the function is bound to, and
 * `oldtable`/`newtable` from the bindings' transition-table names.
 *
 * Aggregating over ALL of a function's bindings (rather than picking one row)
 * matters: `handle_field_searchable_update` is bound with both names, while a
 * function bound many times may declare a different table per binding, and any
 * of them type-checks the body.
 *
 * What no binding can supply is in OVERRIDES below, each with its reason. A
 * function that still cannot be checked is reported in the skipped list, and a
 * skip that is not in OVERRIDES is called out as unexpected - that list is the
 * point of the report, and it is why this is a command rather than an
 * invocation somebody retypes.
 *
 * Not a gate. Style warnings do not fail builds here, so the exit code is
 * always 0 and the report is read, not enforced.
 *
 *   deno task lint-sql --database-url postgresql://postgres:...@localhost:5432/appdb
 *
 * Needs a migrated database (pgdocker/pg-cli-retest.sh) and plpgsql_check on
 * the server; the extension is installed into schema `extensions` if missing,
 * exactly as the coverage collector does.
 */

import { Client } from "@postgres";
import { join } from "@std/path";

/** The schemas the migrations create. Everything else is somebody else's code. */
const LINT_SCHEMAS = ["public", "common", "rbac", "audit", "pgmq"];

/** Vendored code, counted apart: pgmq is not ours to fix. */
const VENDORED_SCHEMAS = new Set(["pgmq"]);

interface Override {
  /** Relation to type-check a trigger function against. */
  relid?: string;
  oldtable?: string;
  newtable?: string;
  /** Set to leave the function unchecked. */
  skip?: boolean;
  /** Why. Printed with the skip, and read by whoever inherits this list. */
  reason: string;
}

/**
 * What pg_trigger cannot supply. Keep every reason current: an override that
 * has quietly become wrong is worse than none, because the function still lints
 * - against the wrong shape.
 */
const OVERRIDES: Record<string, Override> = {
  "public.raci_emit_trigger_fn": {
    relid: "public.user_bookmarks",
    reason:
      "no trigger binds it in a fresh install - bindings appear only when a " +
      "process gate sets emits_events. The body reads TG_OP, TG_TABLE_NAME " +
      "and to_jsonb(OLD), so any rowtype type-checks it.",
  },
  "public.queue_build_record_json": {
    oldtable: "old_rows",
    reason:
      "the body reads both transition tables, but every trigger bound at " +
      "install time is an INSERT trigger carrying only tgnewtable; the DELETE " +
      "binding that would supply old_rows exists only for entities that opt in.",
  },
  "pgmq.notify_queue_listeners": {
    skip: true,
    reason:
      "vendored, byte-identical to pgmq v1.11.1, and unbound by design - " +
      "Semantius creates no trigger for it. Re-lint at the next re-vendor.",
  },
};

interface FunctionRow {
  oid: number;
  nspname: string;
  identity: string;
  relid: string | null;
  oldtable: string | null;
  newtable: string | null;
}

interface Finding {
  schema: string;
  identity: string;
  lineno: number | null;
  level: string;
  message: string;
}

interface Skip {
  identity: string;
  reason: string;
  expected: boolean;
}

/**
 * Every PL/pgSQL function in the linted schemas, with the check arguments its
 * own bindings imply. `prokind = 'f'` because plpgsql_check_function_tb checks
 * functions; procedures and aggregates are a different entry point.
 */
const FUNCTIONS_SQL = `
WITH bound AS (
  SELECT t.tgfoid AS fnoid,
         min(t.tgrelid)::regclass::text AS relid,
         max(t.tgoldtable) AS oldtable,
         max(t.tgnewtable) AS newtable
    FROM pg_catalog.pg_trigger t
   GROUP BY t.tgfoid
)
SELECT p.oid::int AS oid,
       n.nspname,
       n.nspname || '.' || p.proname AS identity,
       b.relid,
       b.oldtable,
       b.newtable
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_catalog.pg_language l ON l.oid = p.prolang
  LEFT JOIN bound b ON b.fnoid = p.oid
 WHERE l.lanname = 'plpgsql'
   AND p.prokind = 'f'
   AND n.nspname = ANY($1)
 ORDER BY n.nspname, p.proname`;

/** Double-quotes an identifier for interpolation into SQL. */
function quoteIdent(name: string): string {
  return '"' + name.replace(/"/g, '""') + '"';
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** One line, whitespace-collapsed: findings carry embedded newlines. */
function oneLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Installs plpgsql_check if the server has it, and says where it landed. */
async function resolveChecker(client: Client): Promise<string> {
  const avail = await client.queryObject<{ installed_version: string | null }>(
    `SELECT installed_version FROM pg_catalog.pg_available_extensions
      WHERE name = 'plpgsql_check'`,
  );
  if (avail.rows.length === 0) {
    throw new Error(
      "plpgsql_check is not available on this server; nothing to lint with",
    );
  }
  if (!avail.rows[0].installed_version) {
    await client.queryArray(`CREATE SCHEMA IF NOT EXISTS extensions`);
    await client.queryArray(
      `CREATE EXTENSION IF NOT EXISTS plpgsql_check WITH SCHEMA extensions`,
    );
  }
  const ext = await client.queryObject<{ schema: string; version: string }>(
    `SELECT n.nspname AS schema, e.extversion AS version
       FROM pg_catalog.pg_extension e
       JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'plpgsql_check'`,
  );
  return ext.rows[0].schema;
}

export async function lintSqlCommand(
  databaseUrl: string,
  outDir = "coverage",
): Promise<void> {
  const client = new Client(databaseUrl);
  await client.connect();

  const lines: string[] = [];
  const emit = (line = "") => {
    lines.push(line);
    console.log(line);
  };

  try {
    const checkSchema = await resolveChecker(client);
    const version = (await client.queryObject<{ v: string }>(
      `SELECT extversion AS v FROM pg_catalog.pg_extension
        WHERE extname = 'plpgsql_check'`,
    )).rows[0].v;

    const fns = (await client.queryObject<FunctionRow>({
      text: FUNCTIONS_SQL,
      args: [LINT_SCHEMAS],
    })).rows;

    const findings: Finding[] = [];
    const skipped: Skip[] = [];
    let checked = 0;

    for (const fn of fns) {
      const ov = OVERRIDES[fn.identity];
      if (ov?.skip) {
        skipped.push({
          identity: fn.identity,
          reason: ov.reason,
          expected: true,
        });
        continue;
      }
      // An event-trigger function takes no relid and a plain function ignores
      // one, so `0` - the argument's own default - is right for both. Only a
      // trigger function needs a real relation, which makes an unbound trigger
      // function with no override exactly the case plpgsql_check refuses, and
      // that is how it lands in `skipped` instead of passing silently.
      const relid = ov?.relid ?? fn.relid ?? null;
      const oldtable = ov?.oldtable ?? fn.oldtable ?? null;
      const newtable = ov?.newtable ?? fn.newtable ?? null;

      try {
        const res = await client.queryObject<
          { lineno: number | null; level: string; message: string }
        >({
          text: `SELECT lineno, level, message
                   FROM ${quoteIdent(checkSchema)}.plpgsql_check_function_tb(
                          $1::oid::regprocedure,
                          relid                  => coalesce($2::regclass, 0),
                          oldtable               => $3,
                          newtable               => $4,
                          security_warnings      => true,
                          performance_warnings   => true,
                          extra_warnings         => true,
                          compatibility_warnings => true)`,
          args: [fn.oid, relid, oldtable, newtable],
        });
        checked++;
        for (const r of res.rows) {
          findings.push({
            schema: fn.nspname,
            identity: fn.identity,
            lineno: r.lineno,
            level: r.level,
            message: r.message,
          });
        }
      } catch (error) {
        // plpgsql_check raised instead of reporting: the function could not be
        // checked at all. Never silent - an unexpected skip is the signal Q6
        // asked this command to make visible.
        skipped.push({
          identity: fn.identity,
          reason: oneLine(errorMessage(error)),
          expected: false,
        });
      }
    }

    // ------------------------------------------------------------- the report
    emit(`plpgsql_check ${version} (schema ${checkSchema})`);
    emit(`schemas: ${LINT_SCHEMAS.join(", ")}`);
    emit();

    for (const f of findings) {
      emit(`${f.identity}:${f.lineno ?? "-"} ${f.level} ${oneLine(f.message)}`);
    }
    if (findings.length === 0) emit("no findings");
    emit();

    emit("findings by schema:");
    for (const s of LINT_SCHEMAS) {
      const n = findings.filter((f) => f.schema === s).length;
      const tag = VENDORED_SCHEMAS.has(s) ? "  (vendored)" : "";
      emit(`  ${s.padEnd(8)} ${String(n).padStart(4)}${tag}`);
    }
    const ours = findings.filter((f) => !VENDORED_SCHEMAS.has(f.schema)).length;
    emit(
      `  ${"total".padEnd(8)} ${String(findings.length).padStart(4)}` +
        `  (${ours} outside the vendored schemas)`,
    );
    emit();

    emit(`checked: ${checked} of ${fns.length} PL/pgSQL functions`);
    emit(`skipped: ${skipped.length}`);
    for (const s of skipped) {
      emit(`  ${s.expected ? "" : "unexpected skip: "}${s.identity}`);
      emit(`      ${s.reason}`);
    }
    const unexpected = skipped.filter((s) => !s.expected).length;
    if (unexpected > 0) {
      emit();
      emit(
        `${unexpected} function(s) could not be checked and are not in ` +
          `OVERRIDES. Give each a relid - and transition-table names, for a ` +
          `statement-level trigger function - in lint_sql.ts, or record there ` +
          `why it is skipped.`,
      );
    }

    // Not a gate: the exit code stays 0 whatever the report says.
    await Deno.mkdir(outDir, { recursive: true });
    const path = join(outDir, "lint.txt");
    await Deno.writeTextFile(path, lines.join("\n") + "\n");
    console.log(`\nWritten to ${path}`);
  } finally {
    await client.end();
  }
}
