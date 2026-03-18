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
    "/** Returns the bundled migrations for a given app name, sorted by filename. */",
    "export function getBundledMigrations(appName: string): MigrationFile[] {",
    "  const appMigrations = MIGRATIONS_BUNDLE[appName];",
    "  if (!appMigrations) return [];",
    "  return Object.entries(appMigrations)",
    "    .sort(([a], [b]) => a.localeCompare(b))",
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

async function bundleSql(): Promise<void> {
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
        if (entry.isFile && entry.name.endsWith(".sql")) {
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

    sqlFiles.sort();

    if (sqlFiles.length === 0) {
      continue;
    }

    console.log(`\n  ${appName}: ${sqlFiles.length} migration file(s)`);
    bundle[appName] = {};

    for (const fileName of sqlFiles) {
      const filePath = join(migrationsPath, fileName);
      const content = await Deno.readTextFile(filePath);
      const migrationName = fileName.replace(/\.sql$/, "");
      bundle[appName][migrationName] = content;
      console.log(`    - ${migrationName} (${content.length} chars)`);
    }
  }

  const appCount = Object.keys(bundle).length;
  const totalMigrations = Object.values(bundle).reduce(
    (sum, app) => sum + Object.keys(app).length,
    0,
  );

  // Write bundle to all output paths
  for (const outputPath of OUTPUT_PATHS) {
    // Derive a package name from the path for the bundle header comment
    const packageMatch = outputPath.match(/packages\/([^/]+)\//);
    const packageName = packageMatch
      ? `@semantius/${packageMatch[1]}`
      : outputPath;
    const output = generateBundleSource(packageName, bundle);
    await Deno.writeTextFile(outputPath, output);
    console.log(`\nBundle written to: ${outputPath}`);
  }

  console.log(
    `\nTotal: ${appCount} app(s), ${totalMigrations} migration(s) bundled.`,
  );
}

await bundleSql();
