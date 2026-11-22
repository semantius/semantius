/**
 * Unit pins for generator behavior nothing else can fail on: LF
 * normalization, the manifest checksum, and the order in which an upgrade
 * script replaces the read-only functions.
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
import {
  compareVersions,
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

Deno.test("versions.json records sha256hex(toLf(source))", async () => {
  // Pins what the manifest hashes: SHA-256 hex of the normalized file text, no
  // prefix, keyed `<app>/<full file name>`. 0020_settings.once.sql is a
  // run-once migration, which the generator refuses to let anyone edit once a
  // release contains it, so the newest manifest entry and the file on disk
  // must agree.
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
    recorded,
    `${KEY} in ${newest} does not match the migration on disk`,
  );
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
