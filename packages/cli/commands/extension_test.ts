/**
 * Unit pins for generator behavior nothing else can fail on: LF
 * normalization, the hash part of the manifest's values, the ts each build
 * mode stamps, the order in which an upgrade script replaces the read-only
 * functions, and where migrate() checks the database's version.
 *
 * Why a test and not a byte grep. On a fresh checkout `.gitattributes`
 * (`* text=auto eol=lf`) makes the whole tree LF, so the generator would keep
 * producing CR-free output with `toLf` deleted - and that LF checkout is the
 * one CI, and therefore the release guard, builds from. The only check that
 * fails when the normalizer is removed is one that hands it CRLF itself, which
 * is what the first test does. The lifecycle script's CR counts on the shipped
 * files stay alongside as pins for a CR arriving by some other route.
 *
 *   deno test --allow-read packages/cli/commands/extension_test.ts
 */

import { dirname, fromFileUrl, join } from "@std/path";
import { UNRELEASED_TS, versionHash } from "@semantius/core";
import {
  compareVersions,
  developmentValue,
  latestRealTs,
  releaseTs,
  releaseValues,
  renderInstaller,
  sha256hex,
  toLf,
} from "./extension.ts";

const REPO_ROOT = join(dirname(fromFileUrl(import.meta.url)), "..", "..", "..");

function assertEquals(actual: unknown, expected: unknown, msg: string): void {
  if (actual !== expected) {
    throw new Error(`${msg}\n  expected: ${expected}\n  actual:   ${actual}`);
  }
}

Deno.test("toLf normalizes CRLF and lone CR before hashing", async () => {
  // Same logical text, three line-ending conventions: one digest.
  const crlf = await sha256hex(toLf("a\r\nb\rc\r\n"));
  const lf = await sha256hex(toLf("a\nb\nc\n"));
  assertEquals(crlf, lf, "a CRLF/CR source must hash like its LF form");

  // And the digest is the one an LF source produces unnormalized, so the
  // manifest values do not shift if a caller ever forgets the call.
  assertEquals(
    lf,
    await sha256hex("a\nb\nc\n"),
    "toLf must be a no-op on text that is already LF",
  );
});

Deno.test("versions.json records the hash part as sha256hex(toLf(source))", async () => {
  // Pins what the manifest hashes: the hash part of each value is the SHA-256
  // hex of the normalized file text, keyed `<app>/<full file name>`; the ts in
  // front of it is the generator's own (developmentValue, releaseValues).
  // 0020_settings.once.sql is a run-once migration, which the generator
  // refuses to let anyone edit once a release contains it, so the newest
  // manifest entry and the file on disk must agree.
  const KEY = "_core/0020_settings.once.sql";

  const manifest = JSON.parse(
    await Deno.readTextFile(join(REPO_ROOT, "extension", "versions.json")),
  ) as { versions: Record<string, { files: Record<string, string> }> };

  const versions = Object.keys(manifest.versions).sort(compareVersions);
  const newest = versions[versions.length - 1];
  if (!newest) throw new Error("extension/versions.json records no version");

  const recorded = manifest.versions[newest].files[KEY];
  if (!recorded) throw new Error(`${newest} records no checksum for ${KEY}`);

  const source = await Deno.readTextFile(
    join(REPO_ROOT, "apps", "_core", "migrations", "0020_settings.once.sql"),
  );
  assertEquals(
    await sha256hex(toLf(source)),
    versionHash(recorded),
    `${KEY} in ${newest} does not match the migration on disk`,
  );
});

// Hashes and ts values for the stamping rules. Only their form matters.
const HA = "a".repeat(64);
const HB = "b".repeat(64);
const HC = "c".repeat(64);
const UNRELEASED = (hash: string) => `${UNRELEASED_TS}.${hash}`;

Deno.test("development mode: a changed file gets the unreleased ts, an unchanged one keeps its value", () => {
  assertEquals(
    developmentValue(`20260101000000.${HA}`, HA),
    `20260101000000.${HA}`,
    "a stamped value with the same hash is kept",
  );
  assertEquals(
    developmentValue(`20260101000000.${HA}`, HB),
    UNRELEASED(HB),
    "a changed file",
  );
  assertEquals(
    developmentValue(HA, HA),
    UNRELEASED(HA),
    "a plain value, as 0.5.0-beta1 recorded them",
  );
  assertEquals(developmentValue(undefined, HA), UNRELEASED(HA), "no value");
  assertEquals(
    developmentValue(UNRELEASED(HA), HA),
    UNRELEASED(HA),
    "an unreleased value stays as it is",
  );
});

Deno.test("release mode: the run's ts is never earlier than the latest real ts plus 1 s", () => {
  const now = new Date(Date.UTC(2026, 10, 22, 10, 11, 12));
  assertEquals(releaseTs(now, undefined), "20261122101112", "UTC now");
  assertEquals(
    releaseTs(now, "20260101000000"),
    "20261122101112",
    "an earlier ts",
  );
  assertEquals(
    releaseTs(now, "20261122101112"),
    "20261122101113",
    "the same second",
  );
  assertEquals(
    releaseTs(now, "20261231235959"),
    "20270101000000",
    "UTC date arithmetic",
  );
  assertEquals(
    latestRealTs(
      {
        versions: { "0.1.0": { files: { a: `20260101000000.${HA}`, b: HB } } },
      },
      {
        versions: {
          "0.2.0": { files: { a: UNRELEASED(HA), c: `20260301000000.${HC}` } },
        },
      },
    ),
    "20260301000000",
    "the latest real ts of all versions of both manifests; the unreleased ts is not real",
  );
});

Deno.test("release mode: one ts for all unreleased files; restored, kept and plain values", () => {
  const now = new Date(Date.UTC(2026, 10, 22, 10, 11, 12));
  const T0 = "20260101000000";
  const R = "20261122101112";
  const hashes = { kept: HA, reverted: HA, changed: HB, added: HC, plain: HA };
  const values = releaseValues(
    hashes,
    {
      kept: `${T0}.${HA}`,
      reverted: UNRELEASED(HB),
      changed: UNRELEASED(HB),
      added: UNRELEASED(HC),
      plain: UNRELEASED(HA),
    },
    {
      kept: `${T0}.${HA}`,
      reverted: `${T0}.${HA}`,
      changed: `${T0}.${HA}`,
      plain: HA,
    },
    T0,
    now,
  );
  assertEquals(values.kept, `${T0}.${HA}`, "an unchanged file keeps its ts");
  assertEquals(
    values.reverted,
    `${T0}.${HA}`,
    "a reverted file gets the tag's value back",
  );
  assertEquals(
    values.changed,
    `${R}.${HB}`,
    "a changed file gets the run's ts",
  );
  assertEquals(values.added, `${R}.${HC}`, "an added file gets the same ts");
  assertEquals(values.plain, `${R}.${HA}`, "a plain tag value is not restored");

  // A restarted release finds its first run's values in the working tree and
  // keeps them, even though its clock has moved on.
  const later = new Date(Date.UTC(2026, 10, 22, 11, 0, 0));
  const again = releaseValues(
    hashes,
    values,
    {
      kept: `${T0}.${HA}`,
      reverted: `${T0}.${HA}`,
    },
    R,
    later,
  );
  assertEquals(
    JSON.stringify(again),
    JSON.stringify(values),
    "a restarted release keeps its values",
  );
});

Deno.test("migrate() checks the database's version inside the ledger block, before the first file", () => {
  const migs = [
    {
      app: "_core",
      name: "0010_probe.once.sql",
      content: "SELECT 1;\n",
      processed: "SELECT 1;\n",
      checksum: `20260101000000.${HA}`,
    },
    {
      app: "_core",
      name: "0020_probe.sql",
      content: "SELECT 2;\n",
      processed: "SELECT 2;\n",
      checksum: UNRELEASED(HB),
    },
  ];
  for (const upgrade of [false, true]) {
    const sql = renderInstaller("pg_semantius", migs, { upgrade });
    const ddl = sql.indexOf("CREATE TABLE IF NOT EXISTS _versions");
    const check = sql.indexOf("v_core   jsonb :=");
    const handler = sql.indexOf(
      "EXCEPTION WHEN OTHERS THEN\n    PERFORM pg_catalog.pg_advisory_unlock",
      ddl,
    );
    const firstFile = sql.indexOf("-- _core.0010_probe.once.sql");
    const what = upgrade ? "upgrade" : "install";
    if (!(ddl > 0 && ddl < check && check < handler && handler < firstFile)) {
      throw new Error(
        `${what}: the check must sit after the ledger DDL, inside the block whose handler releases the lock, before the first file`,
      );
    }
    // The handler releases the lock; an unlock of its own would release it a
    // second time.
    const block = sql.slice(check, handler);
    if (block.includes("pg_advisory_unlock")) {
      throw new Error(
        `${what}: the check must leave the unlock to the handler`,
      );
    }
    for (
      const text of [
        "_core in this database contains % from a newer pg_semantius build (%); this runner''s newest is %; use a newer pg_semantius, then ALTER EXTENSION pg_semantius UPDATE and CALL semantius.migrate()",
        "run-once migration % in this database differs from this version: this database cannot be updated; replace the database with a fresh install",
        "migration % in this database is not part of this version: this database cannot be updated; replace the database with a fresh install",
        "USING ERRCODE = '55000'",
        `v_newest text := '${UNRELEASED_TS}'`,
      ]
    ) {
      if (!block.includes(text)) {
        throw new Error(`${what}: the check lacks ${text}`);
      }
    }
  }
});

Deno.test("an upgrade drops the read-only functions before creating them", () => {
  // CREATE OR REPLACE cannot change a result type, so the first release that
  // changes status()'s columns needs the drop to come first, or
  // ALTER EXTENSION ... UPDATE fails with 42P13. No release with different
  // columns exists yet, and no harness runs an upgrade script, so the
  // rendered text is the only place the order can be checked.
  const migs = [{
    app: "_core",
    name: "0010_probe.sql",
    content: "SELECT 1;\n",
    processed: "SELECT 1;\n",
    checksum: "0".repeat(64),
  }];
  const upgrade = renderInstaller("pg_semantius", migs, { upgrade: true });
  for (const fn of ["status", "pending", "version"]) {
    const drop = upgrade.indexOf(`DROP FUNCTION IF EXISTS semantius.${fn}();`);
    const create = upgrade.indexOf(`CREATE FUNCTION semantius.${fn}()`);
    if (drop < 0) throw new Error(`the upgrade script does not drop ${fn}()`);
    if (create < 0) {
      throw new Error(`the upgrade script does not create ${fn}()`);
    }
    if (drop > create) {
      throw new Error(`the upgrade script creates ${fn}() before dropping it`);
    }
  }

  // The full install creates the schema in the same script, so there is
  // nothing to drop, and the install script stays what it was.
  const install = renderInstaller("pg_semantius", migs, { upgrade: false });
  if (install.includes("DROP FUNCTION IF EXISTS semantius.status()")) {
    throw new Error("the full install must not drop status()");
  }
});
