/**
 * How this CLI was started, which is also how every example and hint has to be
 * spelled back to the user.
 *
 * The same code ships two ways: as `deno task <cmd>` from a checkout, and as
 * the compiled `pg_semantius` executable. A help text that hardcodes either
 * spelling hands half its readers a command line that does not run.
 */

import { basename } from "@std/path";

/**
 * True when the executable is deno itself, i.e. `deno run` / `deno task`.
 * `deno compile` produces a normal executable, so this is also the test for
 * "am I the binary" - which decides whether commands that need a checkout
 * (init, lint, format) are offered at all.
 */
export const RUNNING_UNDER_DENO = (() => {
  const exe = basename(Deno.execPath());
  return exe === "deno" || exe === "deno.exe";
})();

/** Prefix for a runnable command, e.g. `${INVOCATION} migrate --apps _core`. */
export const INVOCATION = RUNNING_UNDER_DENO ? "deno task" : "pg_semantius";

/**
 * Prefix for the flags-only form. `deno task --help` would print deno's own
 * task help, so the task runner needs the explicit `start` entry point; the
 * binary takes the flag directly.
 */
export const HELP_INVOCATION = RUNNING_UNDER_DENO
  ? "deno task start"
  : "pg_semantius";
