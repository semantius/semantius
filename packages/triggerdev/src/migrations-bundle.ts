/**
 * Auto-generated SQL migrations bundle for @semantius/triggerdev.
 * DO NOT EDIT MANUALLY - regenerate with: deno task bundle-sql
 *
 * This file is a placeholder. Run `deno task bundle-sql` from the project root
 * to populate it with the actual SQL migration content before building.
 *
 * The generated version of this file is excluded from git (.gitignore).
 */

export interface MigrationFile {
  name: string;
  content: string;
}

/** Returns the bundled migrations for a given app name, sorted by filename. */
export function getBundledMigrations(appName: string): MigrationFile[] {
  const appMigrations = MIGRATIONS_BUNDLE[appName];
  if (!appMigrations) return [];
  return Object.entries(appMigrations)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, content]) => ({ name, content }));
}

/** Returns all app names that have bundled migrations. */
export function getBundledAppNames(): string[] {
  return Object.keys(MIGRATIONS_BUNDLE).sort();
}

const MIGRATIONS_BUNDLE: Record<string, Record<string, string>> = {};
