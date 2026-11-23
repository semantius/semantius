/**
 * Build-level tests of the run rules: the extension generator's guards over
 * released migrations and the values it stamps in each mode, the loaders'
 * refusal of duplicate numbers and dollar-tag collisions, and the guards the
 * CLI's script mode writes. Each of those runs the real CLI in a scratch
 * directory whose own apps/_core shadows the checkout's
 * (packages/cli/assets.ts), so nothing in the repository is touched. The
 * CLI's manifest lookup and its question about a local _core are pure
 * functions, tested directly.
 *
 *   deno test -A packages/cli/commands/migrate_build_test.ts
 */

import { dirname, fromFileUrl, join } from "@std/path";
import { sha256hex } from "./extension.ts";
import {
  acceptsLocalCore,
  asksBeforeLocalCore,
  manifestFiles,
  migrationVersion,
} from "./migrate.ts";

const CLI = join(dirname(fromFileUrl(import.meta.url)), "..", "cli.ts");

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

function assertEquals(actual: unknown, expected: unknown, msg: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${msg}\n  expected: ${e}\n  actual:   ${a}`);
}

function assertThrows(fn: () => unknown, pattern: RegExp, msg: string): void {
  try {
    fn();
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error);
    assert(pattern.test(text), `${msg}: wrong error "${text}"`);
    return;
  }
  throw new Error(`${msg}: nothing was thrown`);
}

/** Runs the CLI in `cwd`; returns the exit code and the combined output. */
async function cli(
  cwd: string,
  ...args: string[]
): Promise<{ code: number; out: string }> {
  const { code, stdout, stderr } = await new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", CLI, ...args],
    cwd,
    stdout: "piped",
    stderr: "piped",
    env: { NO_COLOR: "1" },
  }).output();
  const dec = new TextDecoder();
  return { code, out: dec.decode(stdout) + dec.decode(stderr) };
}

/** A scratch project holding apps/_core/migrations with the given files. */
async function project(files: Record<string, string>): Promise<string> {
  const dir = await Deno.makeTempDir({ prefix: "pgsem_build_" });
  const mig = join(dir, "apps", "_core", "migrations");
  await Deno.mkdir(mig, { recursive: true });
  for (const [name, text] of Object.entries(files)) {
    await Deno.writeTextFile(join(mig, name), text);
  }
  return dir;
}

const mig = (dir: string, name: string) =>
  join(dir, "apps", "_core", "migrations", name);

const RELEASED = {
  "0010_schema.once.sql": "CREATE TABLE t (id int);\n",
  "0020_code.sql": "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 1';\n",
  "0030_entities.jsonc": '// entities\n{"version": 1}\n',
  "9900_harden.sql": "SELECT 1;\n",
};

/** A project with RELEASED built as 0.1.0, ready for a 0.2.0 build. */
async function released(): Promise<string> {
  const dir = await project(RELEASED);
  const r = await cli(dir, "extension", "0.1.0");
  assert(r.code === 0, `building 0.1.0 failed:\n${r.out}`);
  return dir;
}

Deno.test("extension build: a released repeatable file may change", async () => {
  const dir = await released();
  await Deno.writeTextFile(
    mig(dir, "0020_code.sql"),
    "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 2';\n",
  );
  await Deno.writeTextFile(mig(dir, "0030_entities.jsonc"), '{"version": 1, "entities": []}\n');
  const r = await cli(dir, "extension", "0.2.0");
  assert(r.code === 0, `a changed .sql/.jsonc must be accepted:\n${r.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: a released .once. file may not change", async () => {
  const dir = await released();
  await Deno.writeTextFile(mig(dir, "0010_schema.once.sql"), "CREATE TABLE t (id bigint);\n");
  const r = await cli(dir, "extension", "0.2.0");
  assert(r.code !== 0, "an edited released .once. file must be refused");
  assert(/run-once migration\(s\) that 0\.1\.0/.test(r.out), `message:\n${r.out}`);
  const waived = await cli(dir, "extension", "0.2.0", "--allow-edited-migrations");
  assert(waived.code === 0, `--allow-edited-migrations waives it:\n${waived.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: a renamed released file is refused", async () => {
  const dir = await released();
  await Deno.rename(mig(dir, "0020_code.sql"), mig(dir, "0020_code2.sql"));
  const r = await cli(dir, "extension", "0.2.0");
  assert(r.code !== 0, "a rename must be refused");
  assert(/no longer\s+exist/.test(r.out) && r.out.includes("_core/0020_code.sql"), `message:\n${r.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: an added file must sort after the released ones", async () => {
  const dir = await released();
  await Deno.writeTextFile(mig(dir, "0015_early.sql"), "SELECT 1;\n");
  const r = await cli(dir, "extension", "0.2.0");
  assert(r.code !== 0, "an added file sorting before a released one must be refused");
  assert(r.out.includes("_core/0015_early.sql") && r.out.includes("last shipped: 0030_entities.jsonc"), `message:\n${r.out}`);
  // After the last released file, and a new 99xx file, are fine.
  await Deno.remove(mig(dir, "0015_early.sql"));
  await Deno.writeTextFile(mig(dir, "0040_late.once.sql"), "SELECT 1;\n");
  await Deno.writeTextFile(mig(dir, "9910_more.sql"), "SELECT 1;\n");
  const ok = await cli(dir, "extension", "0.2.0");
  assert(ok.code === 0, `files after the last released one are accepted:\n${ok.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("loaders: duplicate numbers are refused by the build and by script mode", async () => {
  const dir = await project({ ...RELEASED, "0020_other.once.sql": "SELECT 1;\n" });
  const ext = await cli(dir, "extension", "0.1.0");
  assert(ext.code !== 0 && /share the number 0020/.test(ext.out), `extension:\n${ext.out}`);
  const script = await cli(dir, "migrate", "--apps", "_core", "--script");
  assert(script.code !== 0, `script mode must fail:\n${script.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: a migration containing an installer dollar tag is refused", async () => {
  const dir = await project({ ...RELEASED, "0040_tag.sql": "SELECT $pgsem_jsonc$x$pgsem_jsonc$;\n" });
  const r = await cli(dir, "extension", "0.1.0");
  assert(r.code !== 0 && r.out.includes("$pgsem_jsonc$"), `tag collision:\n${r.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("script mode: each file is guarded by its run rule", async () => {
  const dir = await project(RELEASED);
  const r = await cli(dir, "migrate", "--apps", "_core", "--script");
  assert(r.code === 0, `script mode failed:\n${r.out}`);
  const sql = await Deno.readTextFile(join(dir, "migrate.sql"));
  assert(sql.startsWith("-- Generated migration script\n\\set ON_ERROR_STOP on\n"), "ON_ERROR_STOP first");
  assert(sql.includes("pg_try_advisory_lock(pg_catalog.hashtext('migrate'))"), "takes the migration lock");
  // .once.: row only. Repeatable: row AND checksum.
  assert(
    sql.includes("IF NOT EXISTS (SELECT 1 FROM public._versions WHERE name = '_core.0010_schema.once.sql') THEN"),
    "a .once. file is guarded by its row alone",
  );
  assert(
    /IF NOT EXISTS \(SELECT 1 FROM public\._versions WHERE name = '_core\.0020_code\.sql' AND checksum = '[0-9a-f]{64}'\) THEN/.test(sql),
    "a repeatable file is guarded by its row and checksum",
  );
  assert(
    sql.includes("EXECUTE $pgsem__core_0030_entities_jsonc$SELECT public.ensure_entities(public.jsonc_to_jsonb($pgsem_jsonc$// entities"),
    "a .jsonc runs as the ensure_entities() call",
  );
  assert(
    /IF pg_catalog\.current_setting\('pgsem\.ran', true\) = 'on'\s+OR NOT EXISTS \(SELECT 1 FROM public\._versions WHERE name = '_core\.9900_harden\.sql'/.test(sql),
    "a 9900 file also runs when another file ran",
  );
  await Deno.remove(dir, { recursive: true });
});

// Version values. Only their form matters.
const HA = "a".repeat(64);
const HB = "b".repeat(64);
const T0 = "20260101000000";
const STAMPED = /^\d{14}\.[0-9a-f]{64}$/;
const UNRELEASED_TS = "99999999999999";

Deno.test("CLI lookup: a _core file takes the build's value only for the very text the build holds", () => {
  const files = manifestFiles({
    versions: {
      "0.9.0": { files: { "_core/0010_a.sql": `${T0}.${HB}` } },
      "0.10.0": {
        files: {
          "_core/0010_a.sql": `${T0}.${HA}`,
          "_core/0020_b.once.sql": `${UNRELEASED_TS}.${HA}`,
          "nwind/0010_a.sql": `${T0}.${HA}`,
        },
      },
    },
  });
  assertEquals(files["_core/0010_a.sql"], `${T0}.${HA}`, "the highest version by semver, not by text");
  assertEquals(migrationVersion(files, "_core", "0010_a.sql", HA), `${T0}.${HA}`, "key and hash match");
  assertEquals(
    migrationVersion(files, "_core", "0020_b.once.sql", HA),
    `${UNRELEASED_TS}.${HA}`,
    "the unreleased ts is a value like any other",
  );
  assertEquals(migrationVersion(files, "_core", "0010_a.sql", HB), HB, "another text: plain");
  assertEquals(migrationVersion(files, "_core", "0030_local.sql", HA), HA, "a file the build lacks: plain");
  assertEquals(migrationVersion(files, "nwind", "0010_a.sql", HA), HA, "nwind: plain");
  assertEquals(migrationVersion(files, "test", "0010_a.sql", HA), HA, "test: plain");
});

Deno.test("CLI lookup: an unreadable manifest is refused, naming it", () => {
  const named = /^cannot read the version manifest extension\/versions\.json: /;
  for (
    const raw of [
      undefined,
      null,
      "text",
      {},
      { versions: {} },
      { versions: { "0.1.0": {} } },
      { versions: { "0.1.0": { files: { "_core/0010_a.sql": 1 } } } },
    ]
  ) {
    assertThrows(() => manifestFiles(raw), named, `manifest ${JSON.stringify(raw)}`);
  }
});

Deno.test("local _core question: asked by the binary when a _core from the working directory has a file without a ts", () => {
  const ask = (over: Partial<Parameters<typeof asksBeforeLocalCore>[0]>) =>
    asksBeforeLocalCore({
      underDeno: false,
      confirm: false,
      source: "cwd",
      versions: [`${T0}.${HA}`, HB],
      ...over,
    });
  assert(ask({}), "any file without a ts is asked about, in migrate and in script mode alike");
  assert(!ask({ versions: [`${T0}.${HA}`, `${UNRELEASED_TS}.${HB}`] }), "the unreleased ts counts as a ts");
  assert(!ask({ confirm: true }), "--confirm skips the question");
  assert(
    !ask({ confirm: true, source: "cwd" }),
    "reset and retest pass confirm, so they do not ask",
  );
  assert(!ask({ source: "embedded" }), "the build's own _core is not asked about");
  assert(!ask({ underDeno: true }), "a checkout run is a development build and does not ask");
  // Only exactly Y applies it; prompt() answers null without a terminal.
  assert(acceptsLocalCore("Y"), "Y applies it");
  for (const answer of [null, "", "y", "yes", "Y "]) {
    assert(!acceptsLocalCore(answer), `${JSON.stringify(answer)} refuses (exit 1)`);
  }
});

Deno.test("script mode: the version check comes after the lock and the ledger, before the first file", async () => {
  const dir = await project(RELEASED);
  const r = await cli(dir, "migrate", "--apps", "_core", "--script");
  assert(r.code === 0, `script mode failed:\n${r.out}`);
  const sql = await Deno.readTextFile(join(dir, "migrate.sql"));
  const lock = sql.indexOf("pg_try_advisory_lock");
  const ledger = sql.indexOf("CREATE TABLE IF NOT EXISTS _versions");
  const check = sql.indexOf("-- Refuse a database this build must not update");
  const first = sql.indexOf("-- Migration: _core.0010_schema.once.sql");
  assert(lock < ledger && ledger < check && check < first, "lock, ledger, check, files");
  const block = sql.slice(check, first);
  // Each refusal releases the lock before it raises: psql would hold it until
  // it exits.
  const raises = block.split("RAISE EXCEPTION").length - 1;
  const unlocks = block.split("PERFORM pg_catalog.pg_advisory_unlock").length - 1;
  assert(raises === 3 && unlocks === 3, `an unlock before each of the 3 raises (${unlocks}/${raises})`);
  assert(block.includes("USING ERRCODE = '55000'"), "SQLSTATE 55000");
  assert(block.includes("replace the database with a fresh install"), "the replace text");
  // This _core is the scratch project's own, which the build does not hold:
  // plain values, and no ts to compare with.
  assert(block.includes("v_newest text := NULL;"), "no latest ts");
  assert(
    /"0010_schema\.once\.sql":\{"value":"[0-9a-f]{64}","once":true\}/.test(block),
    "the runner's own values, plain",
  );
  await Deno.remove(dir, { recursive: true });
});

Deno.test("script mode: the build's own _core carries its stamped values", async () => {
  // No apps/ in the working directory: _core comes with the CLI, and its
  // values from extension/versions.json.
  const dir = await Deno.makeTempDir({ prefix: "pgsem_build_" });
  const r = await cli(dir, "migrate", "--apps", "_core", "--script");
  assert(r.code === 0, `script mode failed:\n${r.out}`);
  const sql = await Deno.readTextFile(join(dir, "migrate.sql"));
  const recorded = [
    ...sql.matchAll(/INSERT INTO public\._versions \(name, checksum\) VALUES \('_core\.[^']+', '([^']+)'\)/g),
  ].map((m) => m[1]);
  assert(recorded.length > 0, "the script records _core files");
  assert(
    recorded.some((v) => STAMPED.test(v)),
    "the shipped files are recorded with stamped values (regenerate the build if extension/versions.json is stale)",
  );
  assert(/v_newest text := '\d{14}';/.test(sql), "the check knows the latest ts");
  await Deno.remove(dir, { recursive: true });
});

/** The scratch project's manifest. */
async function readManifest(
  dir: string,
): Promise<Record<string, Record<string, string>>> {
  const m = JSON.parse(
    await Deno.readTextFile(join(dir, "extension", "versions.json")),
  ) as { versions: Record<string, { files: Record<string, string> }> };
  return Object.fromEntries(
    Object.entries(m.versions).map(([v, { files }]) => [v, files]),
  );
}

/** Writes a manifest, `version -> key -> value`, to `path`. */
async function writeManifest(
  path: string,
  versions: Record<string, Record<string, string>>,
): Promise<void> {
  await Deno.writeTextFile(
    path,
    JSON.stringify({
      versions: Object.fromEntries(
        Object.entries(versions).map(([v, files]) => [v, { files }]),
      ),
    }, null, 2) + "\n",
  );
}

/** Every RELEASED file's key with the given value of its own hash. */
async function stampAll(
  files: Record<string, string>,
  value: (hash: string) => string,
): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const [name, text] of Object.entries(files)) {
    out[`_core/${name}`] = value(await sha256hex(text));
  }
  return out;
}

Deno.test("extension build: development mode stamps changed files as unreleased and keeps unchanged ones", async () => {
  const dir = await released();
  const first = (await readManifest(dir))["0.1.0"];
  assert(
    Object.values(first).every((v) => v.startsWith(`${UNRELEASED_TS}.`) && STAMPED.test(v)),
    `a first build has no released content: ${JSON.stringify(first)}`,
  );

  // As if 0.1.0 had been released at T0, then 0020 changed.
  const manifestPath = join(dir, "extension", "versions.json");
  await writeManifest(manifestPath, { "0.1.0": await stampAll(RELEASED, (h) => `${T0}.${h}`) });
  const code2 = "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 2';\n";
  await Deno.writeTextFile(mig(dir, "0020_code.sql"), code2);
  const r = await cli(dir, "extension", "0.1.0");
  assert(r.code === 0, `regenerating failed:\n${r.out}`);
  const after = (await readManifest(dir))["0.1.0"];
  assertEquals(after["_core/0020_code.sql"], `${UNRELEASED_TS}.${await sha256hex(code2)}`, "the changed file");
  const schema = `${T0}.${await sha256hex(RELEASED["0010_schema.once.sql"])}`;
  assertEquals(after["_core/0010_schema.once.sql"], schema, "an unchanged file keeps its value");

  // The installer records exactly these values.
  const install = await Deno.readTextFile(join(dir, "extension", "pg_semantius--0.1.0.sql"));
  assert(
    install.includes(`VALUES ('_core.0010_schema.once.sql', '${schema}')`) &&
      install.includes(`VALUES ('_core.0020_code.sql', '${after["_core/0020_code.sql"]}')`),
    "migrate() records the manifest's values",
  );

  // A second run changes nothing.
  const bytes = await Deno.readTextFile(manifestPath);
  const again = await cli(dir, "extension", "0.1.0");
  assert(again.code === 0, `the second run failed:\n${again.out}`);
  assertEquals(await Deno.readTextFile(manifestPath), bytes, "deterministic");
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: after plain entries, as 0.5.0-beta1 has, the edit guard and --check compare the hash part", async () => {
  const dir = await released();
  const manifestPath = join(dir, "extension", "versions.json");
  await writeManifest(manifestPath, { "0.1.0": await stampAll(RELEASED, (h) => h) });
  const r = await cli(dir, "extension", "0.2.0");
  assert(r.code === 0, `0.2.0 after plain 0.1.0 entries must build:\n${r.out}`);
  const values = (await readManifest(dir))["0.2.0"];
  assert(
    Object.values(values).every((v) => v.startsWith(`${UNRELEASED_TS}.`)),
    `plain entries become unreleased: ${JSON.stringify(values)}`,
  );
  const check = await cli(dir, "extension", "0.2.0", "--check");
  assert(check.code === 0, `--check passes:\n${check.out}`);

  // Another ts with the same hash is not a change to the migrations...
  const versions = await readManifest(dir);
  const key = "_core/0010_schema.once.sql";
  const hash = values[key].slice(15);
  versions["0.2.0"][key] = `${T0}.${hash}`;
  await writeManifest(manifestPath, versions);
  const ts = await cli(dir, "extension", "0.2.0", "--check");
  assert(ts.code === 0, `a different ts alone passes --check:\n${ts.out}`);
  // ...another hash is.
  versions["0.2.0"][key] = `${T0}.${HA}`;
  await writeManifest(manifestPath, versions);
  const stale = await cli(dir, "extension", "0.2.0", "--check");
  assert(stale.code !== 0 && stale.out.includes(`changed  ${key}`), `another hash fails --check:\n${stale.out}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: --release stamps one ts, keeps and restores released values, and restarts cleanly", async () => {
  const dir = await released();
  const manifestPath = join(dir, "extension", "versions.json");
  const tag = await stampAll(RELEASED, (h) => `${T0}.${h}`);
  await writeManifest(manifestPath, { "0.1.0": tag });
  const tagPath = join(dir, "tag-versions.json");
  await writeManifest(tagPath, { "0.1.0": tag });

  const code2 = "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 2';\n";
  await Deno.writeTextFile(mig(dir, "0020_code.sql"), code2);
  await Deno.writeTextFile(mig(dir, "0040_new.sql"), "SELECT 4;\n");
  const r = await cli(dir, "extension", "0.2.0", "--release", tagPath);
  assert(r.code === 0, `release build failed:\n${r.out}`);
  const v = (await readManifest(dir))["0.2.0"];
  const runTs = v["_core/0020_code.sql"].slice(0, 14);
  assert(STAMPED.test(v["_core/0020_code.sql"]) && runTs > T0 && runTs !== UNRELEASED_TS, `a real ts after T0: ${runTs}`);
  assertEquals(v["_core/0040_new.sql"].slice(0, 14), runTs, "one ts for all unreleased files");
  for (const k of ["_core/0010_schema.once.sql", "_core/0030_entities.jsonc", "_core/9900_harden.sql"]) {
    assertEquals(v[k], tag[k], `${k} keeps its released value`);
  }

  // A restarted release keeps what the first run wrote.
  const bytes = await Deno.readTextFile(manifestPath);
  const again = await cli(dir, "extension", "0.2.0", "--release", tagPath);
  assert(again.code === 0, `restart failed:\n${again.out}`);
  assertEquals(await Deno.readTextFile(manifestPath), bytes, "a restarted release keeps its values");

  // A reverted file gets the tag's value back; a file changed again gets a ts
  // never earlier than one second after the latest real ts of either manifest.
  await Deno.writeTextFile(mig(dir, "0020_code.sql"), RELEASED["0020_code.sql"]);
  await Deno.writeTextFile(mig(dir, "0040_new.sql"), "SELECT 40;\n");
  const future = join(dir, "future-versions.json");
  await writeManifest(future, { "0.1.0": { ...tag, "_core/0005_x.sql": `20991231235959.${HB}` } });
  const later = await cli(dir, "extension", "0.2.0", "--release", future);
  assert(later.code === 0, `release build failed:\n${later.out}`);
  const w = (await readManifest(dir))["0.2.0"];
  assertEquals(w["_core/0020_code.sql"], tag["_core/0020_code.sql"], "the reverted file has its released value");
  assertEquals(
    w["_core/0040_new.sql"],
    `21000101000000.${await sha256hex("SELECT 40;\n")}`,
    "latest real ts plus 1 s",
  );
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: --release over plain tag values stamps every file with the run's ts", async () => {
  // A re-release of a version whose tag recorded plain values, as 0.5.0-beta1
  // did: no plain value is restored.
  const dir = await released();
  const tagPath = join(dir, "tag-versions.json");
  await writeManifest(tagPath, { "0.1.0": await stampAll(RELEASED, (h) => h) });
  const r = await cli(dir, "extension", "0.1.0", "--release", tagPath);
  assert(r.code === 0, `release build failed:\n${r.out}`);
  const v = Object.values((await readManifest(dir))["0.1.0"]);
  const ts = new Set(v.map((x) => x.slice(0, 14)));
  assert(v.every((x) => STAMPED.test(x)) && ts.size === 1 && !ts.has(UNRELEASED_TS), `one real ts: ${JSON.stringify(v)}`);
  await Deno.remove(dir, { recursive: true });
});

Deno.test("extension build: --release refuses --check and a manifest it cannot use", async () => {
  const dir = await released();
  const both = await cli(dir, "extension", "0.1.0", "--check", "--release", "x.json");
  assert(both.code !== 0 && both.out.includes("--release cannot be combined with --check"), `with --check:\n${both.out}`);
  const missing = await cli(dir, "extension", "0.1.0", "--release", join(dir, "missing.json"));
  assert(missing.code !== 0 && missing.out.includes("cannot read the release manifest"), `missing:\n${missing.out}`);
  for (const text of ['{"versions": {}}\n', '{"versions": {"0.1.0": {}}}\n']) {
    const empty = join(dir, "empty.json");
    await Deno.writeTextFile(empty, text);
    const none = await cli(dir, "extension", "0.1.0", "--release", empty);
    assert(
      none.code !== 0 && none.out.includes("records no version with a file list"),
      `${text.trim()}:\n${none.out}`,
    );
  }
  await Deno.remove(dir, { recursive: true });
});
