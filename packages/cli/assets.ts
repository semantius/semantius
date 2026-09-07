/**
 * Locates the `apps/<name>/{migrations,tests}` SQL the CLI reads.
 *
 * Every read used to be `./apps/...`, which is only correct when the process
 * was started from a checkout. `deno compile --include apps` ships that SQL
 * inside the executable, and the embedded copy is mounted under a temporary
 * directory that only exists while the binary runs - so nothing here may
 * assume the working directory holds the repository.
 *
 * Two roots are searched, in this order: `./apps` under the working directory,
 * then the copy that ships with the CLI. The precedence is PER APP, not per
 * root: a working-directory app wins over an embedded one of the same name -
 * that is what lets the released binary run somebody else's SQL - while the
 * embedded copy still supplies every app the working directory does not have,
 * so `migrate --apps _core,myapp` works with only `myapp` on disk.
 */

import { join, resolve } from "@std/path";

export type AppsSource = "cwd" | "embedded";

export interface AppsRoot {
  path: string;
  source: AppsSource;
}

export interface ResolvedApp {
  name: string;
  /** Absolute path of `<root>/<name>`. */
  dir: string;
  source: AppsSource;
}

/**
 * An app name indexes one directory under a root, so it may not travel out of
 * it. Without this, `--apps ../../etc` resolved and the CLI read - and for
 * `extension`, shipped - whatever it pointed at.
 */
const APP_NAME = /^[A-Za-z0-9_-]+$/;

const APP_NAME_RULE = 'the name may contain only letters, digits, "_" and "-"';

/**
 * The invariant, checked where the name is about to be joined onto a root.
 * It throws rather than exits because it guards a library call, not a command
 * line; validateAppNames() is what a command uses to reject a typo.
 */
export function validateAppName(app: string): void {
  if (!APP_NAME.test(app)) {
    throw new Error(
      `invalid app name "${app}": an app is a directory under apps/, so ` +
        APP_NAME_RULE,
    );
  }
}

/**
 * The boundary check, run once on a parsed `--apps` list before anything is
 * read. It exits instead of throwing: a mistyped app name is a user error, and
 * a stack trace is not an answer to one.
 */
export function validateAppNames(apps: string[]): void {
  for (const app of apps) {
    if (APP_NAME.test(app)) continue;
    console.error(
      `invalid app name "${app}": an app is a directory under apps/, so ` +
        APP_NAME_RULE,
    );
    Deno.exit(1);
  }
}

/**
 * The copy of `apps/` that ships with the CLI.
 *
 * Derived from this module's own location, never from the working directory
 * and never hardcoded. A compiled binary mounts its embedded files under a
 * temporary directory it names after the executable, and mirrors the
 * repository layout below that, so `packages/cli/../../apps` lands on the
 * embedded `apps/` no matter where the binary was built or what it was renamed
 * to. `join`/`resolve` pick their separator from `Deno.build.os` at runtime,
 * which is what makes a Windows executable cross-compiled on Linux build
 * Windows paths.
 */
export function embeddedAppsRoot(): string {
  return resolve(import.meta.dirname!, "..", "..", "apps");
}

let rootsPromise: Promise<AppsRoot[]> | undefined;

/** The roots to search, highest precedence first. Discovered once per run. */
export function appsRoots(): Promise<AppsRoot[]> {
  rootsPromise ??= discoverRoots();
  return rootsPromise;
}

async function discoverRoots(): Promise<AppsRoot[]> {
  const embedded = embeddedAppsRoot();
  const roots: AppsRoot[] = [];

  // Running `deno task ...` from the checkout, the two roots ARE the same
  // directory. Listing it twice would make every app shadow itself and print a
  // notice about a binary that does not exist, so it collapses to one entry.
  const cwd = resolve(Deno.cwd(), "apps");
  if (await isDirectory(cwd) && !(await samePath(cwd, embedded))) {
    roots.push({ path: cwd, source: "cwd" });
  }
  roots.push({ path: embedded, source: "embedded" });

  for (const root of roots) {
    console.info(`SQL apps root: ${root.path} (${root.source})`);
  }
  return roots;
}

/** Apps notified about once each, so a repeated lookup stays quiet. */
const shadowReported = new Set<string>();

export async function resolveAppDir(
  app: string,
): Promise<ResolvedApp | undefined> {
  validateAppName(app);

  const hits: ResolvedApp[] = [];
  for (const root of await appsRoots()) {
    const dir = join(root.path, app);
    if (await isDirectory(dir)) {
      hits.push({ name: app, dir, source: root.source });
    }
  }

  if (hits.length === 0) return undefined;

  // Shadowing is legitimate and is never silent: the two copies can disagree,
  // and "which SQL did this database actually get" is the first question asked
  // when an install does not look like the release it claims to be. Both
  // resolved paths are named rather than described - the loser is only "the
  // copy in the binary" when there IS a binary, and `deno run` from a
  // directory that has its own apps/ reaches here too.
  if (hits.length > 1 && !shadowReported.has(app)) {
    shadowReported.add(app);
    console.log(`apps/${app}: using ${hits[0].dir}, not ${hits[1].dir}`);
  }

  return hits[0];
}

/**
 * The apps a command should act on when it was given no list.
 *
 * Only the highest-precedence root that actually holds apps contributes. A
 * working directory with its own apps/ is somebody's project, and `test` there
 * has to run that project's suites - not also the `test` and `nwind` suites
 * the CLI happens to carry, which fail unless those apps were migrated too.
 * Answering "which apps?" from the union is what caused that; answering "where
 * does app X live?" from the union stays correct, and resolveAppDir still does.
 *
 * With a single root - a checkout, or a directory with no apps/ of its own -
 * this is exactly listApps().
 */
export async function listPrimaryApps(): Promise<string[]> {
  for (const root of await appsRoots()) {
    const names = await appsIn(root);
    if (names.length > 0) return names;
  }
  return [];
}

/**
 * Every app name either root offers, sorted, without duplicates. For a caller
 * building a lookup table rather than choosing what to run, where a surplus
 * entry costs nothing and a missing one loses information.
 */
export async function listApps(): Promise<string[]> {
  const names = new Set<string>();
  for (const root of await appsRoots()) {
    for (const name of await appsIn(root)) names.add(name);
  }
  return [...names].sort();
}

/** The app directories directly under one root, sorted. */
async function appsIn(root: AppsRoot): Promise<string[]> {
  const names: string[] = [];
  try {
    for await (const entry of Deno.readDir(root.path)) {
      // isSymlink as well as isDirectory: readDir does not follow links,
      // while the Deno.stat in resolveAppDir does. Without it a symlinked
      // apps/<name> is migratable by name and invisible to every command
      // that enumerates - test and coverage would silently skip it.
      if ((entry.isDirectory || entry.isSymlink) && APP_NAME.test(entry.name)) {
        names.push(entry.name);
      }
    }
  } catch {
    // A root that cannot be listed simply contributes no apps; the caller's
    // "not found" path is the right report, not a crash here.
  }
  return names.sort();
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await Deno.stat(path)).isDirectory;
  } catch {
    return false;
  }
}

/**
 * Symlink-aware where it can be: a checkout reached through a symlinked path
 * must still collapse to one root. `Deno.realPath` has no meaning inside the
 * compiled file system and throws there, and the computed strings are already
 * absolute and normalized, so comparing them is the correct fallback.
 */
async function samePath(a: string, b: string): Promise<boolean> {
  try {
    return (await Deno.realPath(a)) === (await Deno.realPath(b));
  } catch {
    return a === b;
  }
}
