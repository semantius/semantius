#!/usr/bin/env deno run --allow-read --allow-write --allow-env

import { parse } from "@std/flags";
import { load } from "@std/dotenv";
import { formatProject } from "./commands/format.ts";
import { initProject } from "./commands/init.ts";
import { migrateCommand } from "./commands/migrate.ts";
import { connectDatabaseConnection } from "./commands/connect.ts";
import { testCommand } from "./commands/test.ts";
import { dropallCommand } from "./commands/dropall.ts";
import { docgenCommand } from "./commands/docgen.ts";
import { resetCommand } from "./commands/reset.ts";
import { red, yellow } from "@std/fmt/colors";

const originalError = console.error;
const originalWarn = console.warn;

console.error = (...args: any[]) => {
  originalError(...args.map(arg => typeof arg === 'string' ? red(arg) : arg));
};

console.warn = (...args: any[]) => {
  originalWarn(...args.map(arg => typeof arg === 'string' ? yellow(arg) : arg));
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
  env?: string;
  "database-url"?: string;
  _: string[];
}

// Read version from the CLI package's deno.json
async function getVersion(): Promise<string> {
  try {
    // Resolve deno.json relative to this file (packages/cli/deno.json)
    const cliDir = new URL(".", import.meta.url).pathname;
    const denoConfig = JSON.parse(
      await Deno.readTextFile(`${cliDir}/deno.json`),
    );
    return denoConfig.version || "unknown";
  } catch {
    return "unknown";
  }
}

const VERSION = await getVersion();

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
    const envVars = await load({ envPath });
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

function showHelp(): void {
  console.log(`
Semantius CLI v${VERSION}

USAGE:
    deno task [COMMAND] [OPTIONS]
    deno task start [COMMAND] [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    --version               Show version information
    -v, --verbose           Enable verbose output
    --config <FILE>         Specify config file path
    --output <DIR>          Specify output directory
    --apps <APPS>           Comma-separated list of app names (for migrate command)
    --confirm               Skip confirmation prompt (for dropall and reset commands)
    --script                Generate SQL file instead of executing (migrate.sql for migrate, dropall.sql for dropall)
    --env <ENV>             Environment name to load (default: local, loads .env.<ENV> file)
    --database-url <URL>    Database connection URL (overrides DATABASE_URL env variable and .env file)

COMMANDS:
    init             Initialize a new project
    build            Build the project
    connect          Test database connection
    test             Run test command with optional --tap flag
    lint             Run linter
    format           Format code
    migrate          Process and validate app folders (requires --apps parameter)
    dropall          ⚠️ DROP ALL database objects in public schema (DESTRUCTIVE!)
    reset            ⚠️ Drop all, migrate --apps test, and run tests (requires --confirm)
    docgen           Generate schema.md documentation from entities metadata

EXAMPLES:
    deno task init
    deno task build --output ./dist
    deno task connect --verbose
    deno task connect --database-url postgresql://user:pass@host:5432/db
    deno task test --tap
    deno task migrate --apps app1,app2,app3 --verbose
    deno task migrate --apps nwind,_ddtest
    deno task migrate --apps nwind --script
    deno task migrate --apps nwind --database-url postgresql://user:pass@host:5432/db
    deno task dropall --verbose
    deno task dropall --confirm
    deno task dropall --script
    deno task reset --confirm
    deno task reset --confirm --verbose
    deno task connect --env test
    deno task migrate --apps nwind --env staging
  `);
}

function showVersion(): void {
  console.log(`Semantius CLI v${VERSION}`);
}

async function buildProject(outputDir: string = "./dist"): Promise<void> {
  console.log(`🔨 Building project to ${outputDir}...`);
  
  try {
    // Ensure output directory exists
    await Deno.mkdir(outputDir, { recursive: true });
    
    // Compile the main application
    const command = new Deno.Command("deno", {
      args: [
        "compile",
        "--allow-read",
        "--allow-write",
        "--allow-env",
        "--output",
        `${outputDir}/semantius-core`,
        "src/main.ts"
      ],
    });
    
    const { code } = await command.output();
    
    if (code === 0) {
      console.log("✅ Build completed successfully!");
      console.log(`📦 Executable created at: ${outputDir}/semantius-core`);
    } else {
      console.error("❌ Build failed!");
      Deno.exit(1);
    }
    
  } catch (error) {
    console.error("❌ Build error:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}

async function lintProject(): Promise<void> {
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
    console.error("❌ Linter error:", error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}

async function main(): Promise<void> {
  const args = parse(Deno.args, {
    boolean: ["help", "version", "verbose", "tap", "confirm", "script"],
    string: ["config", "output", "apps", "env", "database-url"],
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
  let databaseUrl: string | undefined;
  databaseUrl = await getDatabaseUrl(
    args.env || "local",
    args["database-url"],
  );
  
  switch (command) {
    case "init":
      await initProject();
      break;
      
    case "build":
      await buildProject(args.output);
      break;
      
    case "connect":
      await connectDatabaseConnection(databaseUrl!);
      break;
      
    case "test":
      await testCommand(databaseUrl!, args.tap);
      break;
      
    case "lint":
      await lintProject();
      break;
      
    case "format":
    case "fmt":
      await formatProject();
      break;
      
    case "migrate": {
      // Use --apps flag if provided, otherwise use positional arguments after "migrate"
      const appsParam = args.apps || (args._.length > 1 ? args._.slice(1).join(",") : "");
      await migrateCommand(appsParam, databaseUrl!, args.script || false);
      break;
    }
      
    case "dropall":
      await dropallCommand(databaseUrl!, args.confirm || false, args.script || false);
      break;

    case "reset":
      await resetCommand(databaseUrl!, args.confirm || false);
      break;
      
    case "docgen":
      await docgenCommand(databaseUrl!);
      break;
      
    default:
      if (command) {
        console.error(`❌ Unknown command: ${command}`);
        console.log("Run 'deno task start --help' for usage information.");
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