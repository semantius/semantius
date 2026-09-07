#!/usr/bin/env deno run --allow-read --allow-write --allow-env

import { parse } from "@std/flags";
import { load } from "@std/dotenv";
import { formatProject } from "./commands/format.ts";
import { initProject } from "./commands/init.ts";
import { migrateCommand } from "./commands/migrate.ts";
import { connectDatabaseConnection } from "./commands/connect.ts";
import { testCommand } from "./commands/test.ts";
import type { CoverageOptions } from "./commands/coverage.ts";
import { dropallCommand } from "./commands/dropall.ts";
import { docgenCommand } from "./commands/docgen.ts";
import { drizzlegenCommand } from "./commands/drizzlegen.ts";
import { kyselygenCommand } from "./commands/kyselygen.ts";
import { resetCommand } from "./commands/reset.ts";
import { retestCommand } from "./commands/retest.ts";
import { testgenJsonlogicCommand } from "./commands/testgen_jsonlogic.ts";
import { extensionCommand } from "./commands/extension.ts";
import { red, yellow } from "@std/fmt/colors";
import {
  HELP_INVOCATION,
  INVOCATION,
  RUNNING_UNDER_DENO,
} from "./invocation.ts";
import denoJson from "./deno.json" with { type: "json" };

const originalError = console.error;
const originalWarn = console.warn;

console.error = (...args: any[]) => {
  originalError(...args.map((arg) => typeof arg === "string" ? red(arg) : arg));
};

console.warn = (...args: any[]) => {
  originalWarn(
    ...args.map((arg) => typeof arg === "string" ? yellow(arg) : arg),
  );
};

interface CliArgs {
  help?: boolean;
  version?: boolean;
  verbose?: boolean;
  config?: string;
  output?: string;
  apps?: string;
  tap?: boolean;
  confirm?: boolean;
  script?: boolean;
  failfast?: boolean;
  coverage?: boolean;
  /** Deprecated no-op: the released-migration check is always on now. */
  strict?: boolean;
  /** `extension --allow-edited-migrations`: waive the released-migration check. */
  "allow-edited-migrations"?: boolean;
  "coverage-min"?: string;
  env?: string;
  "database-url"?: string;
  _: string[];
}

/** The commands that open a database connection; see main(). */
const DATABASE_COMMANDS = new Set([
  "connect",
  "test",
  "migrate",
  "dropall",
  "reset",
  "retest",
  "docgen",
  "drizzlegen",
  "kyselygen",
]);

/**
 * What this program calls itself, everywhere it names itself.
 *
 * NOT "Semantius CLI": `semantius-cli` is a different, unrelated product - an
 * MCP client - whose executable is `semantius` and whose installer puts it in
 * the same directory this one installs into. Two neighbors called "Semantius
 * <something> CLI" reporting different versions read as one tool that failed
 * to upgrade. This is the extension's name, the executable's name, and the
 * name a user typed to get here, which is the only identity that cannot be
 * confused with anything else.
 */
const PROGRAM = "pg_semantius";

/** One line, for the help banner: what the program is for. */
const TAGLINE =
  "Deploy and test a Semantius database - migrations, RBAC and RLS policies,\n" +
  "the pgTAP suite - and build the PostgreSQL extension.";

/**
 * The CLI version, inlined at compile time. A static import is what makes
 * `deno compile` embed the file; reading it from disk at runtime only ever
 * worked from a checkout, which is exactly what the binary exists to escape.
 * `release.sh` writes this field, and CI refuses a tag that disagrees with it.
 */
const VERSION: string = denoJson.version;

async function getDatabaseUrl(
  env: string = "local",
  cliUrl?: string,
): Promise<string> {
  // --database-url flag takes highest priority
  if (cliUrl) {
    return cliUrl;
  }

  // DATABASE_URL env var takes next priority — checked before loading the .env
  // file so that CI environments and devcontainers work without requiring a
  // .env.local file to be present.
  const envVar = Deno.env.get("DATABASE_URL");
  if (envVar) {
    return envVar;
  }

  // Fall back to loading from .env.<env> file
  try {
    const envPath = `.env.${env}`;
    // examplePath and defaultsPath are switched off rather than left at their
    // defaults: load() otherwise reads ./.env.example and throws
    // MissingEnvVarsError when it names a variable the environment does not
    // define. This repository has exactly such a file, so the binary run from
    // the checkout would fail on the example instead of on the .env it was
    // asked for.
    const envVars = await load({
      envPath,
      examplePath: null,
      defaultsPath: null,
    });
    const databaseUrl = envVars.DATABASE_URL;

    if (!databaseUrl) {
      console.error(
        `DATABASE_URL not found in ${envPath} or in environment variables`,
      );
      console.log(
        `Set DATABASE_URL in your ${envPath} file, as an environment variable, or pass --database-url <URL>`,
      );
      Deno.exit(1);
    }

    return databaseUrl;
  } catch (error) {
    console.error(
      "Failed to load environment variables:",
      error instanceof Error ? error.message : String(error),
    );
    console.log(
      `Set DATABASE_URL in your .env.${env} file, as an environment variable, or pass --database-url <URL>`,
    );
    Deno.exit(1);
  }
}

/**
 * Coverage options for `test` / `retest`. `--coverage-min <pct>` implies
 * `--coverage`; the percentage is validated here so a typo fails before any
 * database work starts. Returns undefined when coverage was not requested.
 */
function parseCoverageOptions(args: CliArgs): CoverageOptions | undefined {
  const minArg = args["coverage-min"];
  if (!args.coverage && minArg === undefined) return undefined;
  let min: number | undefined;
  if (minArg !== undefined) {
    min = Number(minArg);
    if (minArg.trim() === "" || !Number.isFinite(min) || min < 0 || min > 100) {
      console.error(
        `--coverage-min must be a number between 0 and 100 (got "${minArg}")`,
      );
      Deno.exit(1);
    }
  }
  return { enabled: true, min, outDir: "coverage" };
}

function showHelp(): void {
  // init, lint and format all need a checkout - init scaffolds a Deno project,
  // the other two shell out to the deno executable - so the compiled binary
  // does not offer them. Listing a command that can only refuse is worse than
  // not listing it at all.
  const usage = RUNNING_UNDER_DENO
    ? `    deno task [COMMAND] [OPTIONS]
    deno task start [COMMAND] [OPTIONS]`
    : `    pg_semantius [COMMAND] [OPTIONS]`;

  const initCommand = RUNNING_UNDER_DENO
    ? "    init             Initialize a new project\n"
    : "";
  const checkoutCommands = RUNNING_UNDER_DENO
    ? "    lint             Run linter\n" +
      "    format           Format code\n"
    : "";

  const examples = [
    ...(RUNNING_UNDER_DENO ? ["init"] : []),
    "connect --verbose",
    "connect --database-url postgresql://user:pass@host:5432/db",
    "test --tap",
    "test --failfast",
    "test 0010*",
    "test 0015_test_jsonlogic.sql",
    "test --coverage",
    "test --coverage --coverage-min 80",
    "migrate --apps app1,app2,app3 --verbose",
    "migrate --apps nwind,_ddtest",
    "migrate --apps nwind --script",
    "migrate --apps nwind --database-url postgresql://user:pass@host:5432/db",
    "extension 0.5.0",
    "extension 0.5.0 --strict",
    "extension 0.5.0 --output ./extension",
    "dropall --verbose",
    "dropall --confirm",
    "dropall --script",
    "reset --confirm",
    "reset --confirm --verbose",
    "retest --confirm",
    "retest --confirm --failfast",
    "retest --confirm --coverage",
    "connect --env test",
    "migrate --apps nwind --env staging",
    "drizzlegen",
    "drizzlegen --output bearer-auth-experimental/examples/drizzle/src/schema",
    "kyselygen",
    "kyselygen --output bearer-auth-experimental/examples/kysely/src/types.ts",
  ].map((example) => `    ${INVOCATION} ${example}`).join("\n");

  console.log(`
${PROGRAM} ${VERSION}
${TAGLINE}

USAGE:
${usage}

OPTIONS:
    -h, --help              Show this help message
    --version               Show version information
    -v, --verbose           Enable verbose output
    --config <FILE>         Specify config file path
    --output <DIR>          Specify output directory
    --apps <APPS>           Comma-separated list of app names (for migrate command)
    --confirm               Skip confirmation prompt (for dropall, reset, and retest commands)
    --script                Generate SQL file instead of executing (migrate.sql for migrate, dropall.sql for dropall)
    --failfast              Stop test execution after the first failed test file (for test and reset commands)
    --coverage              Measure which functions/statements/tables the suite executes (for test and retest);
                            writes coverage/summary.json, coverage/uncovered.md and coverage/lcov.info
    --coverage-min <PCT>    Exit 1 when function coverage is below PCT percent (implies --coverage)
    --env <ENV>             Environment name to load (default: local, loads .env.<ENV> file)
    --database-url <URL>    Database connection URL (overrides DATABASE_URL env variable and .env file)

COMMANDS:
${initCommand}    connect          Test database connection
    test             Run pgTAP tests
    test <PATTERN>   Run only tests matching PATTERN (glob-like, e.g. 0010*)
${checkoutCommands}    migrate          Process and validate app folders (requires --apps parameter)
    extension <VER>  Generate the PostgreSQL extension (control + SQL) into
                     ./extension at an explicit version (e.g. 0.5.0). The version
                     is required. Regenerating the newest version in place is
                     supported; a version is frozen once a higher one is in
                     versions.json. See RELEASE.md.
                     Only migrations ADDED in <VER> may be edited; editing one an
                     earlier version shipped fails the build. Waive with
                     --allow-edited-migrations. (--strict is now the default and
                     is accepted but ignored.)
                     Prefer ./release.sh <VER>, which also tests and tags.
    dropall          ⚠️ DROP ALL database objects in public schema (DESTRUCTIVE!)
    reset            ⚠️ Drop all and migrate --apps _core (requires --confirm)
    retest           ⚠️ Drop all, migrate --apps nwind,test, and run tests (requires --confirm)
    docgen           Generate schema.md documentation from entities metadata
    drizzlegen       Generate a Drizzle ORM schema (one file per module) from the catalog
    kyselygen        Generate Kysely type definitions (a single types file with the DB interface) from the catalog
    testgen_jsonlogic Generate 0015_test_jsonlogic.sql from 0015_test_jsonlogic.json

EXAMPLES:
${examples}
  `);
}

function showVersion(): void {
  console.log(`${PROGRAM} ${VERSION}`);
}

/**
 * `lint` and `format` spawn the deno executable over the checkout's own
 * source. Permissions are baked into a compiled binary, so the spawn would
 * fail there with a NotCapable error naming a flag the user has no way to
 * pass - and even with that permission there would be no source tree to lint.
 * Refuse first, in words that say what to do instead.
 */
function requireCheckout(): void {
  if (RUNNING_UNDER_DENO) return;
  console.error(
    "lint and format run deno lint / deno fmt on a checkout and are not part " +
      "of the pg_semantius binary.",
  );
  Deno.exit(1);
}

async function lintProject(): Promise<void> {
  requireCheckout();
  console.log("🔍 Running linter...");

  try {
    const command = new Deno.Command("deno", {
      args: ["lint"],
    });

    const { code } = await command.output();

    if (code === 0) {
      console.log("✅ No linting issues found!");
    } else {
      console.error("❌ Linting issues found!");
      Deno.exit(1);
    }
  } catch (error) {
    console.error(
      "❌ Linter error:",
      error instanceof Error ? error.message : String(error),
    );
    Deno.exit(1);
  }
}

async function main(): Promise<void> {
  const args = parse(Deno.args, {
    boolean: [
      "help",
      "version",
      "verbose",
      "tap",
      "confirm",
      "script",
      "failfast",
      "coverage",
      "strict",
      "allow-edited-migrations",
    ],
    // "_" keeps positional args as strings; without it @std/flags coerces
    // numeric-looking positionals to numbers and drops leading zeros, which
    // breaks numeric test-file filters like `test 0335` (-> 335, never matches).
    string: [
      "config",
      "output",
      "apps",
      "env",
      "database-url",
      "coverage-min",
      "_",
    ],
    alias: {
      h: "help",
      v: "verbose",
    },
  }) as CliArgs;

  // Override console.info globally based on verbose flag
  if (!args.verbose) {
    console.info = () => {};
  }

  if (args.help) {
    showHelp();
    return;
  }

  if (args.version) {
    showVersion();
    return;
  }

  const command = args._[0];

  // Get database URL for commands that need it.
  // --database-url flag takes priority over env file / DATABASE_URL env var.
  //
  // An allowlist, not "everything except extension": init, lint, format,
  // testgen_jsonlogic, an unknown command and the bare help all used to be
  // stopped by "DATABASE_URL not found" before they could say anything of
  // their own, which is an answer to a question the user never asked.
  // `migrate --script` builds its SQL from the migration files alone, so it
  // drops out of the set as well - that is what lets the binary be smoke-
  // tested, and used, with no database anywhere. `dropall --script` does NOT:
  // it connects and introspects the live catalog to decide what to drop, so
  // exempting it would skip --database-url entirely and let `new Client(
  // undefined)` fall back to PGHOST/PGUSER - writing a drop script for a
  // different database than the one that was configured.
  const scriptOnly = args.script === true && command === "migrate";
  let databaseUrl: string | undefined;
  if (DATABASE_COMMANDS.has(String(command)) && !scriptOnly) {
    databaseUrl = await getDatabaseUrl(
      args.env || "local",
      args["database-url"],
    );
  }

  switch (command) {
    case "init":
      await initProject();
      break;

    case "connect":
      await connectDatabaseConnection(databaseUrl!);
      break;

    case "test": {
      const filter = args._.length > 1 ? String(args._[1]) : undefined;
      await testCommand(
        databaseUrl!,
        args.tap,
        args.failfast,
        filter,
        parseCoverageOptions(args),
      );
      break;
    }

    case "lint":
      await lintProject();
      break;

    case "format":
    case "fmt":
      requireCheckout();
      await formatProject();
      break;

    case "migrate": {
      // Use --apps flag if provided, otherwise use positional arguments after "migrate"
      const appsParam = args.apps ||
        (args._.length > 1 ? args._.slice(1).join(",") : "");
      await migrateCommand(appsParam, databaseUrl!, args.script || false);
      break;
    }

    case "extension": {
      // The version is required. The old fallback to the CLI package's own
      // version wrote a full install at THAT version, pruned the current build
      // and moved default_version backwards. See RELEASE.md.
      if (args._.length <= 1) {
        console.error(
          `extension: a version is required, e.g. \`${INVOCATION} extension 0.5.0\`.`,
        );
        console.error(
          "Regenerating the newest version in place is supported; see RELEASE.md.",
        );
        Deno.exit(1);
      }
      const version = String(args._[1]);
      // --strict is kept parseable on purpose: it appears in committed workflows
      // and in muscle memory, and a hard "unknown flag" failure mid-release is a
      // worse outcome than a warning. It is NOT an alias for the new flag - that
      // would invert its meaning.
      if (args.strict) {
        console.warn(
          "extension: --strict is now the default and is ignored. The " +
            "released-migration check is always on; use " +
            "--allow-edited-migrations to waive it.",
        );
      }
      await extensionCommand({
        apps: args.apps || "_core",
        version,
        name: "pg_semantius",
        outputDir: args.output || "./extension",
        allowEditedMigrations: args["allow-edited-migrations"] === true,
      });
      break;
    }

    case "dropall":
      await dropallCommand(
        databaseUrl!,
        args.confirm || false,
        args.script || false,
      );
      break;

    case "reset":
      await resetCommand(databaseUrl!, args.confirm || false);
      break;

    case "retest":
      await retestCommand(
        databaseUrl!,
        args.confirm || false,
        args.failfast || false,
        parseCoverageOptions(args),
      );
      break;

    case "docgen":
      await docgenCommand(databaseUrl!);
      break;

    case "drizzlegen":
      await drizzlegenCommand(databaseUrl!, args.output || "./drizzle/schema");
      break;

    case "kyselygen":
      await kyselygenCommand(databaseUrl!, args.output || "./kysely/types.ts");
      break;

    case "testgen_jsonlogic":
      await testgenJsonlogicCommand();
      break;

    default:
      if (command) {
        console.error(`❌ Unknown command: ${command}`);
        console.log(`Run '${HELP_INVOCATION} --help' for usage information.`);
        Deno.exit(1);
      } else {
        showHelp();
      }
      break;
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error("❌ Unexpected error:", error);
    Deno.exit(1);
  });
}
