/**
 * Unit pins for the two generator helpers whose behaviour nothing else can
 * fail on: LF normalization and the manifest checksum (B13, R7).
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
import { compareVersions, sha256hex, toLf } from "./extension.ts";

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
  // prefix, keyed `<app>/<name>` without the `.sql`. 0010 is a released
  // migration, which the generator refuses to let anyone edit, so the newest
  // manifest entry and the file on disk must agree forever.
  const KEY = "_core/0010_create_core";

  const manifest = JSON.parse(
    await Deno.readTextFile(join(REPO_ROOT, "extension", "versions.json")),
  ) as { versions: Record<string, { files: Record<string, string> }> };

  const versions = Object.keys(manifest.versions).sort(compareVersions);
  const newest = versions[versions.length - 1];
  if (!newest) throw new Error("extension/versions.json records no version");

  const recorded = manifest.versions[newest].files[KEY];
  if (!recorded) throw new Error(`${newest} records no checksum for ${KEY}`);

  const source = await Deno.readTextFile(
    join(REPO_ROOT, "apps", "_core", "migrations", "0010_create_core.sql"),
  );
  assertEquals(
    await sha256hex(toLf(source)),
    recorded,
    `${KEY} in ${newest} does not match the migration on disk`,
  );
});
