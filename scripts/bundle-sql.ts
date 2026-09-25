#!/usr/bin/env -S deno run --allow-read --allow-write
/**
 * SQL Bundler - Build script for @semantius/triggerdev and @semantius/provisioning
 *
 * Reads SQL migration files from the apps/ directory and bundles their
 * contents into TypeScript files so that the migrate functions can execute
 * them without filesystem access at runtime.
 *
 * Output files:
 *   packages/triggerdev/src/migrations-bundle.ts
 *   packages/provisioning/src/migrations-bundle.ts
 *
 * Usage (from project root):
 *   deno task bundle-sql
 *   # or directly:
 *   deno run --allow-read --allow-write scripts/bundle-sql.ts
 *   # compare the bundles on disk with apps/ and write nothing (exit 1 on a
 *   # difference; the Generated: line is ignored):
 *   deno task bundle-sql --check
 *
 * Every migration file is bundled under its full file name (`0010_core.sql`,
 * `0020_settings.once.sql`, `0300_audit_log.jsonc`): the suffix is what tells
 * the runner in @semantius/core how the file runs, and the name is its ledger
 * key.
 *
 * Apps listed in EXCLUDED_APPS are not bundled (e.g. the "test" app which
 * contains the pgTAP testing framework and is not needed in production).
 *
 * The generated files are NOT committed to git.  Re-run this script whenever
 * SQL migration files change and before building the packages.
 */

import { join } from "https://deno.land/std@0.208.0/path/mod.ts";

// Apps that should NOT be bundled (testing/dev-only apps)
const EXCLUDED_APPS = new Set(["test"]);

// Packages that receive the generated migrations bundle
const OUTPUT_PATHS = [
  "./packages/triggerdev/src/migrations-bundle.ts",
  "./packages/provisioning/src/migrations-bundle.ts",
  "./packages/neon-provisioner/src/migrations-bundle.ts",
];

interface AppMigrations {
  [fileName: string]: string;
}

interface MigrationsBundle {
  [appName: string]: AppMigrations;
}

/** Builds the TypeScript source for a migrations bundle. */
function generateBundleSource(
  packageName: string,
  bundle: MigrationsBundle,
): string {
  const appCount = Object.keys(bundle).length;
  const totalMigrations = Object.values(bundle).reduce(
    (sum, app) => sum + Object.keys(app).length,
    0,
  );

  const lines: string[] = [
    "/**",
    ` * Auto-generated SQL migrations bundle for ${packageName}.`,
    " * DO NOT EDIT MANUALLY - regenerate with: deno task bundle-sql",
    " *",
    ` * Generated: ${new Date().toISOString()}`,
    ` * Apps: ${appCount}  |  Migrations: ${totalMigrations}`,
    " */",
    "",
    "export interface MigrationFile {",
    "  name: string;",
    "  content: string;",
    "}",
    "",
    "/**",
    " * Returns the bundled migrations for a given app name, in byte order of the",
    " * file names - the order every runner uses (not localeCompare, which may",
    " * order `_` and digits differently).",
    " */",
    "export function getBundledMigrations(appName: string): MigrationFile[] {",
    "  const appMigrations = MIGRATIONS_BUNDLE[appName];",
    "  if (!appMigrations) return [];",
    "  return Object.entries(appMigrations)",
    "    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))",
    "    .map(([name, content]) => ({ name, content }));",
    "}",
    "",
    "/** Returns all app names that have bundled migrations. */",
    "export function getBundledAppNames(): string[] {",
    "  return Object.keys(MIGRATIONS_BUNDLE).sort();",
    "}",
    "",
    "const MIGRATIONS_BUNDLE: Record<string, Record<string, string>> = {",
  ];

  for (const [appName, migrations] of Object.entries(bundle)) {
    lines.push(`  ${JSON.stringify(appName)}: {`);
    for (const [migrationName, content] of Object.entries(migrations)) {
      // Use a template literal with escaping to safely embed SQL content
      const escaped = content
        .replace(/\\/g, "\\\\")
        .replace(/`/g, "\\`")
        .replace(/\$\{/g, "\\${");
      lines.push(`    ${JSON.stringify(migrationName)}: \`${escaped}\`,`);
    }
    lines.push("  },");
  }

  lines.push("};");
  lines.push("");

  return lines.join("\n");
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

/** Byte order of two file names, the order every migration runner uses. */
function byteOrder(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** The generated source minus its `Generated:` timestamp line. */
function withoutTimestamp(source: string): string {
  return source.replace(/^ \* Generated: .*$/m, "");
}

async function bundleSql(check: boolean): Promise<void> {
  const appsDir = "./apps";

  console.log("Bundling SQL migration files...");
  console.log(`Source directory: ${appsDir}`);
  if (EXCLUDED_APPS.size > 0) {
    console.log(`Excluded apps: ${[...EXCLUDED_APPS].join(", ")}`);
  }

  const bundle: MigrationsBundle = {};

  // Walk apps directory to find all app folders
  let appDirs: string[] = [];
  try {
    for await (const entry of Deno.readDir(appsDir)) {
      if (entry.isDirectory) {
        appDirs.push(entry.name);
      }
    }
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      console.error(`Apps directory not found: ${appsDir}`);
      console.error(
        "Run this script from the project root (where the apps/ directory is located).",
      );
      Deno.exit(1);
    }
    throw error;
  }

  appDirs.sort();
  const includedDirs = appDirs.filter((d) => !EXCLUDED_APPS.has(d));
  const skippedDirs = appDirs.filter((d) => EXCLUDED_APPS.has(d));
  console.log(
    `\nFound ${appDirs.length} app(s): ${appDirs.join(", ")}`,
  );
  if (skippedDirs.length > 0) {
    console.log(`Skipping: ${skippedDirs.join(", ")}`);
  }

  for (const appName of includedDirs) {
    const migrationsPath = join(appsDir, appName, "migrations");

    let sqlFiles: string[] = [];
    try {
      for await (const entry of Deno.readDir(migrationsPath)) {
        if (
          entry.isFile &&
          (entry.name.endsWith(".sql") || entry.name.endsWith(".jsonc"))
        ) {
          sqlFiles.push(entry.name);
        }
      }
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        // App has no migrations directory - skip silently
        continue;
      }
      throw error;
    }

    sqlFiles.sort(byteOrder);

    if (sqlFiles.length === 0) {
      continue;
    }

    console.log(`\n  ${appName}: ${sqlFiles.length} migration file(s)`);
    bundle[appName] = {};

    for (const fileName of sqlFiles) {
      const filePath = join(migrationsPath, fileName);
      const content = toLf(await Deno.readTextFile(filePath));
      bundle[appName][fileName] = content;
      console.log(`    - ${fileName} (${content.length} chars)`);
    }
  }

  const appCount = Object.keys(bundle).length;
  const totalMigrations = Object.values(bundle).reduce(
    (sum, app) => sum + Object.keys(app).length,
    0,
  );

  // Write bundle to all output paths
  const stale: string[] = [];
  for (const outputPath of OUTPUT_PATHS) {
    // Derive a package name from the path for the bundle header comment
    const packageMatch = outputPath.match(/packages\/([^/]+)\//);
    const packageName = packageMatch
      ? `@semantius/${packageMatch[1]}`
      : outputPath;
    const output = generateBundleSource(packageName, bundle);
    if (check) {
      let current = "";
      try {
        current = await Deno.readTextFile(outputPath);
      } catch (error) {
        if (!(error instanceof Deno.errors.NotFound)) throw error;
      }
      if (withoutTimestamp(current) !== withoutTimestamp(output)) {
        stale.push(outputPath);
      }
      continue;
    }
    await Deno.writeTextFile(outputPath, output);
    console.log(`\nBundle written to: ${outputPath}`);
  }

  if (check) {
    if (stale.length > 0) {
      console.error("\nStale or missing bundles (run: deno task bundle-sql):");
      for (const p of stale) console.error(`  ${p}`);
      Deno.exit(1);
    }
    console.log("\nAll bundles match apps/.");
    return;
  }

  console.log(
    `\nTotal: ${appCount} app(s), ${totalMigrations} migration(s) bundled.`,
  );
}

await bundleSql(Deno.args.includes("--check"));
