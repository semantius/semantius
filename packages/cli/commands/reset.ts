/**
 * Reset command implementation
 * Combines dropall + migrate --apps test + test into a single command
 */

import { dropallCommand } from "./dropall.ts";
import { migrateCommand } from "./migrate.ts";
import { testCommand } from "./test.ts";

export async function resetCommand(databaseUrl: string, confirm: boolean = false, failFast = false): Promise<void> {
  if (!confirm) {
    console.error("ERROR: --confirm flag is required to run the reset command");
    console.log("Usage: deno task reset --confirm");
    console.log("This command will drop all database objects, re-run migrations, and execute tests.");
    Deno.exit(1);
  }

  console.log("Starting reset...");

  // Step 1: Drop all database objects
  console.log("\n--- Step 1/3: dropall ---");
  await dropallCommand(databaseUrl, true, false);

  // Step 2: Migrate with test apps
  console.log("\n--- Step 2/3: migrate --apps cloud,test ---");
  await migrateCommand("cloud,test", databaseUrl, false);

  // Step 3: Run tests
  console.log("\n--- Step 3/3: test ---");
  await testCommand(databaseUrl, false, failFast);

  console.log("\nReset completed successfully!");
}
