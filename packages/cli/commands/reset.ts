/**
 * Reset command implementation
 * Combines dropall + migrate _core into a single command (no tests)
 */

import { dropallCommand } from "./dropall.ts";
import { migrateCommand } from "./migrate.ts";

export async function resetCommand(
  databaseUrl: string,
  confirm: boolean = false,
): Promise<void> {
  if (!confirm) {
    const answer = prompt(
      '⚠️  This will drop all database objects and re-run migrations (_core). Type "yes" to continue:',
    );
    if (answer?.toLowerCase() !== "yes") {
      console.log("Aborted.");
      Deno.exit(0);
    }
  }

  console.log("Starting reset...");

  console.log("\n--- Step 1/2: dropall ---");
  await dropallCommand(databaseUrl, true, false);

  console.log("\n--- Step 2/2: migrate --apps _core ---");
  await migrateCommand("_core", databaseUrl, false);

  console.log("\nReset completed successfully!");
}
