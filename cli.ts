#!/usr/bin/env deno run --allow-read --allow-write --allow-env

import { parse } from "@std/flags";
import { load } from "@std/dotenv";
import { formatProject } from "./commands/format.ts";
import { initProject } from "./commands/init.ts";
import { migrateCommand } from "./commands/migrate.ts";
import { testDatabaseConnection } from "./commands/test.ts";

interface CliArgs {
  help?: boolean;
  version?: boolean;
  verbose?: boolean;
  config?: string;
  output?: string;
  apps?: string;
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
    deno task start [OPTIONS] [COMMAND]

OPTIONS:
    -h, --help       Show this help message
    -v, --version    Show version information
    --verbose        Enable verbose output
    --config <FILE>  Specify config file path
    --output <DIR>   Specify output directory
    --apps <APPS>    Comma-separated list of app names (for migrate command)

COMMANDS:
    init             Initialize a new project
    build            Build the project
    test             Test database connection
    lint             Run linter
    format           Format code
    migrate          Process and validate app folders (requires --apps parameter)

EXAMPLES:
    deno task start init
    deno task start build --output ./dist
    deno task start test --verbose
    deno task start migrate --apps app1,app2,app3
    deno task start migrate --apps nwind,_ddtest
    deno run --allow-read --allow-write --allow-env --allow-net cli.ts test
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
    boolean: ["help", "version", "verbose"],
    string: ["config", "output", "apps"],
    alias: {
      h: "help",
      v: "version",
    },
  }) as CliArgs;

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
      
    case "test":
      await testDatabaseConnection(databaseUrl!);
      break;
      
    case "lint":
      await lintProject();
      break;
      
    case "format":
    case "fmt":
      await formatProject();
      break;
      
    case "migrate":
      // Use --apps flag if provided, otherwise use positional arguments after "migrate"
      const appsParam = args.apps || (args._.length > 1 ? args._.slice(1).join(",") : "");
      await migrateCommand(appsParam, databaseUrl!);
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