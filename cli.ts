#!/usr/bin/env deno run --allow-read --allow-write --allow-env

import { parse } from "@std/flags";
import { load } from "@std/dotenv";
import { formatProject } from "./commands/format.ts";
import { initProject } from "./commands/init.ts";
import { migrateCommand } from "./commands/migrate.ts";
import { connectDatabaseConnection } from "./commands/connect.ts";
import { testCommand } from "./commands/test.ts";
import { dropallCommand } from "./commands/dropall.ts";
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
  _: string[];
}

// Read version from deno.json
async function getVersion(): Promise<string> {
  try {
    const denoConfig = JSON.parse(await Deno.readTextFile("./deno.json"));
    return denoConfig.version || "unknown";
  } catch {
    return "unknown";
  }
}

const VERSION = await getVersion();

async function getDatabaseUrl(): Promise<string> {
  try {
    // Load environment variables from .env.local
    const env = await load({ envPath: ".env.local" });
    const databaseUrl = env.DATABASE_URL || Deno.env.get("DATABASE_URL");
    
    if (!databaseUrl) {
      console.error("❌ DATABASE_URL not found in environment variables or .env.local");
      console.log("💡 Make sure DATABASE_URL is set in your .env.local file");
      Deno.exit(1);
    }
    
    return databaseUrl;
  } catch (error) {
    console.error("❌ Failed to load environment variables:", error instanceof Error ? error.message : String(error));
    console.log("💡 Make sure .env.local file exists and is properly formatted");
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
    -h, --help       Show this help message
    --version        Show version information
    -v, --verbose    Enable verbose output
    --config <FILE>  Specify config file path
    --output <DIR>   Specify output directory
    --apps <APPS>    Comma-separated list of app names (for migrate command)
    --confirm        Skip confirmation prompt (for dropall command)
    --script         Generate migrate.sql file instead of executing (for migrate command)

COMMANDS:
    init             Initialize a new project
    build            Build the project
    connect          Test database connection
    test             Run test command with optional --tap flag
    lint             Run linter
    format           Format code
    migrate          Process and validate app folders (requires --apps parameter)
    dropall          ⚠️ DROP ALL database objects in public schema (DESTRUCTIVE!)

EXAMPLES:
    deno task init
    deno task build --output ./dist
    deno task connect --verbose
    deno task test --tap
    deno task migrate --apps app1,app2,app3 --verbose
    deno task migrate --apps nwind,_ddtest
    deno task dropall --verbose
    deno task dropall --confirm    
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
    string: ["config", "output", "apps"],
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
  
  // Get database URL for commands that need it
  let databaseUrl: string | undefined;  
  databaseUrl = await getDatabaseUrl();  
  
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
      await dropallCommand(databaseUrl!, args.confirm || false);
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