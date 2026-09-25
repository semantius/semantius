/**
 * Build-level tests of the run rules: the extension generator's guards over
 * released migrations, the loaders' refusal of duplicate numbers and dollar-tag
 * collisions, and the guards the CLI's script mode writes. Each test runs the
 * real CLI in a scratch directory whose own apps/_core shadows the checkout's
 * (packages/cli/assets.ts), so nothing in the repository is touched.
 *
 *   deno test -A packages/cli/commands/migrate_build_test.ts
 */

import { dirname, fromFileUrl, join } from "@std/path";

const CLI = join(dirname(fromFileUrl(import.meta.url)), "..", "cli.ts");

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
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
