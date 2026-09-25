/**
 * Unit tests for the run rules in migrate.ts, against an in-memory stand-in
 * for the database: which files run, in which order, what the ledger records,
 * and what happens around a failing file. The same rules are re-implemented in
 * SQL by the extension's migrate()/pending() and by the CLI's script mode;
 * pgdocker/pg-ext-lifecycle.sh exercises those against a real server.
 *
 *   deno test packages/core/src/migrate_test.ts
 */

import {
  type DatabaseClient,
  executeMigrations,
  isFinal,
  isOnce,
  JSONC_TAG,
  migrationChecksum,
  type MigrationFile,
  orderMigrationNames,
  runMigrations,
  shouldRun,
  wrapJsonc,
} from "./migrate.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}
function assertEquals(actual: unknown, expected: unknown, msg: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${msg}\n  expected: ${e}\n  actual:   ${a}`);
}
async function assertRejects(
  fn: () => Promise<unknown> | unknown,
  pattern: RegExp,
  msg: string,
): Promise<void> {
  try {
    await fn();
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error);
    assert(pattern.test(text), `${msg}: wrong error "${text}"`);
    return;
  }
  throw new Error(`${msg}: nothing was thrown`);
}

/**
 * A DatabaseClient that understands exactly the statements the runner sends:
 * the lock, the ledger read and upsert, transaction control, NOTIFY, the
 * _versions DDL, and migration bodies - which it "runs" by recording them and
 * failing when the body contains FAIL.
 */
class FakeDb implements DatabaseClient {
  ledger = new Map<string, string | null>();
  executed: string[] = [];
  locked = false;
  lockHeldElsewhere = false;
  private pending: { name: string; checksum: string } | null = null;
  private tx: string[] = [];
  private inTx = false;

  queryObject(
    sql: string,
    params?: unknown[],
  ): Promise<{ rows: Record<string, unknown>[] }> {
    const s = sql.trim();
    if (s.startsWith("SELECT pg_try_advisory_lock")) {
      const acquired = !this.lockHeldElsewhere;
      if (acquired) this.locked = true;
      return Promise.resolve({ rows: [{ acquired }] });
    }
    if (s.startsWith("SELECT pg_advisory_unlock")) {
      this.locked = false;
      return Promise.resolve({ rows: [{ pg_advisory_unlock: true }] });
    }
    if (s.includes("information_schema.tables")) {
      return Promise.resolve({ rows: [{ exists: true }] });
    }
    if (s.startsWith("CREATE TABLE IF NOT EXISTS _versions")) {
      return Promise.resolve({ rows: [] });
    }
    if (s.startsWith("SELECT checksum FROM public._versions")) {
      assert(this.locked, "a ledger row was read without the migration lock");
      const name = params![0] as string;
      return Promise.resolve({
        rows: this.ledger.has(name) ? [{ checksum: this.ledger.get(name) }] : [],
      });
    }
    if (s === "BEGIN") {
      this.inTx = true;
      this.tx = [];
      this.pending = null;
      return Promise.resolve({ rows: [] });
    }
    if (s === "COMMIT") {
      this.executed.push(...this.tx);
      if (this.pending) {
        this.ledger.set(this.pending.name, this.pending.checksum);
      }
      this.inTx = false;
      return Promise.resolve({ rows: [] });
    }
    if (s === "ROLLBACK") {
      this.inTx = false;
      this.tx = [];
      this.pending = null;
      return Promise.resolve({ rows: [] });
    }
    if (s.startsWith("INSERT INTO public._versions")) {
      assert(this.inTx, "the ledger row was written outside the file's transaction");
      this.pending = {
        name: params![0] as string,
        checksum: params![1] as string,
      };
      return Promise.resolve({ rows: [] });
    }
    if (s.startsWith("NOTIFY")) return Promise.resolve({ rows: [] });
    // A migration body.
    assert(this.inTx, "a migration ran outside a transaction");
    if (s.includes("FAIL")) {
      return Promise.reject(new Error(`boom in: ${s.slice(0, 40)}`));
    }
    this.tx.push(s);
    return Promise.resolve({ rows: [] });
  }
}

const quiet = () => {
  const saved = { info: console.info, error: console.error };
  console.info = () => {};
  console.error = () => {};
  return () => {
    console.info = saved.info;
    console.error = saved.error;
  };
};

Deno.test("file names: suffixes, numbers, finals", () => {
  assert(isOnce("0020_settings.once.sql"), ".once.sql is run-once");
  assert(isOnce("0010_nwind.once.jsonc"), ".once.jsonc is run-once");
  assert(!isOnce("0010_core.sql"), ".sql is repeatable");
  assert(!isOnce("0300_audit_log.jsonc"), ".jsonc is repeatable");
  assert(isFinal("9900_owner_hardening.sql"), "9900 is final");
  assert(!isFinal("0420_module_version.sql"), "0420 is not final");
});

Deno.test("orderMigrationNames: byte order, duplicates and bad names refused", async () => {
  assertEquals(
    orderMigrationNames("app", [
      "9900_z.sql",
      "0020_b.once.sql",
      "0010_a.jsonc",
      "0015_Upper.sql",
    ]),
    ["0010_a.jsonc", "0015_Upper.sql", "0020_b.once.sql", "9900_z.sql"],
    "files run in byte order of their names",
  );
  await assertRejects(
    () => orderMigrationNames("app", ["0010_a.sql", "0010_b.once.sql"]),
    /share the number 0010/,
    "two files with one number",
  );
  await assertRejects(
    () => orderMigrationNames("app", ["10_a.sql"]),
    /not a valid migration file name/,
    "a number that is not four digits",
  );
  await assertRejects(
    () => orderMigrationNames("app", ["0010_a.b.sql"]),
    /not a valid migration file name/,
    "a dot inside the name",
  );
});

Deno.test("shouldRun: the rule matrix", () => {
  const f = (name: string) => ({ name, checksum: "new" });
  // No row: everything runs.
  assert(shouldRun(f("0010_a.sql"), undefined, false), "new repeatable");
  assert(shouldRun(f("0010_a.once.sql"), undefined, false), "new once");
  // Unchanged: nothing runs.
  assert(!shouldRun(f("0010_a.sql"), { checksum: "new" }, false), "unchanged repeatable");
  assert(!shouldRun(f("0010_a.once.sql"), { checksum: "new" }, false), "unchanged once");
  // Changed: repeatable runs, once does not.
  assert(shouldRun(f("0010_a.jsonc"), { checksum: "old" }, false), "changed repeatable");
  assert(!shouldRun(f("0010_a.once.sql"), { checksum: "old" }, false), "changed once");
  // A cleared checksum forces a repeatable file.
  assert(shouldRun(f("0010_a.sql"), { checksum: null }, false), "cleared checksum");
  // 9900: follows any other file that ran.
  assert(!shouldRun(f("9900_h.sql"), { checksum: "new" }, false), "unchanged final, nothing ran");
  assert(shouldRun(f("9900_h.sql"), { checksum: "new" }, true), "unchanged final after a run");
});

Deno.test("wrapJsonc: one ensure_entities call, tag refused inside the text", async () => {
  const sql = wrapJsonc('// c\n{"version": 1}\n');
  assertEquals(
    sql,
    `SELECT public.ensure_entities(public.jsonc_to_jsonb(${JSONC_TAG}// c\n{"version": 1}\n${JSONC_TAG}));\n`,
    "the raw text is quoted verbatim",
  );
  await assertRejects(
    () => wrapJsonc(`{"x": "${JSONC_TAG}"}`),
    /may not contain/,
    "a file containing the tag",
  );
});

Deno.test("executeMigrations: first pass, second pass, changes", async () => {
  const restore = quiet();
  try {
    const db = new FakeDb();
    db.locked = true;
    const files: MigrationFile[] = [
      { name: "0020_code.sql", content: "code v1" },
      { name: "0010_schema.once.sql", content: "schema v1" },
      { name: "0030_entities.jsonc", content: '{"version": 1}' },
      { name: "9900_harden.sql", content: "harden" },
    ];
    const first = await executeMigrations("app", files, db);
    assertEquals(first, { applied: 4, skipped: 0 }, "first pass applies all");
    assertEquals(
      db.executed.map((s) => s.split("\n")[0].slice(0, 30)),
      ["schema v1", "code v1", `SELECT public.ensure_entities(`, "harden"],
      "in byte order, the .jsonc wrapped",
    );
    // The ledger key is the full name, the checksum is of the raw file text
    // (not of the wrapped SQL), as in every other runner.
    assertEquals(
      db.ledger.get("app.0030_entities.jsonc"),
      await migrationChecksum('{"version": 1}'),
      ".jsonc checksum is of the file text",
    );

    db.executed = [];
    const second = await executeMigrations("app", files, db);
    assertEquals(second, { applied: 0, skipped: 4 }, "second pass runs nothing");

    db.executed = [];
    files[0].content = "code v2"; // repeatable: runs
    files[1].content = "schema v2"; // once: does not
    const third = await executeMigrations("app", files, db);
    assertEquals(third, { applied: 2, skipped: 2 }, "changed repeatable + the final");
    assertEquals(db.executed, ["code v2", "harden"], "the 9900 file follows it");
    assertEquals(
      db.ledger.get("app.0010_schema.once.sql"),
      await migrationChecksum("schema v1"),
      "a skipped .once. file keeps its recorded checksum (status() reports it)",
    );
  } finally {
    restore();
  }
});

Deno.test("executeMigrations: a failing file still runs the 9900 files, then rethrows", async () => {
  const restore = quiet();
  try {
    const db = new FakeDb();
    db.locked = true;
    const files: MigrationFile[] = [
      { name: "0010_a.sql", content: "a" },
      { name: "0020_b.sql", content: "b FAIL" },
      { name: "0030_c.sql", content: "c" },
      { name: "9900_harden.sql", content: "harden" },
      { name: "9910_after.sql", content: "after FAIL" },
    ];
    await assertRejects(
      () => executeMigrations("app", files, db),
      /boom in: b FAIL/,
      "the ORIGINAL error is the one thrown",
    );
    assertEquals(db.executed, ["a", "harden"], "a committed, c skipped, finals ran");
    assert(db.ledger.has("app.0010_a.sql"), "a is recorded");
    assert(!db.ledger.has("app.0020_b.sql"), "b is not recorded");
    assert(!db.ledger.has("app.0030_c.sql"), "c did not run");
    assert(db.ledger.has("app.9900_harden.sql"), "the 9900 file is recorded");

    // The next pass resumes at b.
    files[1].content = "b fixed";
    files[4].content = "after";
    db.executed = [];
    await executeMigrations("app", files, db);
    assertEquals(db.executed, ["b fixed", "c", "harden", "after"], "resume at the failed file");
  } finally {
    restore();
  }
});

Deno.test("runMigrations: fails at once while another migration holds the lock", async () => {
  const restore = quiet();
  try {
    const db = new FakeDb();
    db.lockHeldElsewhere = true;
    await assertRejects(
      () => runMigrations(db, [{ app: "app", migrations: [{ name: "0010_a.sql", content: "a" }] }]),
      /another migration is running/,
      "second runner",
    );
    assertEquals(db.executed, [], "nothing ran");

    const free = new FakeDb();
    await runMigrations(free, [{ app: "app", migrations: [{ name: "0010_a.sql", content: "a" }] }]);
    assert(!free.locked, "the lock is released after the run");

    const failing = new FakeDb();
    await assertRejects(
      () => runMigrations(failing, [{ app: "app", migrations: [{ name: "0010_a.sql", content: "FAIL" }] }]),
      /boom/,
      "failing run",
    );
    assert(!failing.locked, "the lock is released after a failure");
  } finally {
    restore();
  }
});
