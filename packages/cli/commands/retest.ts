/**
 * Retest command implementation
 * Combines dropall + migrate --apps nwind,test + test into a single command
 */

import { dropallCommand } from "./dropall.ts";
import { migrateCommand } from "./migrate.ts";
import { testCommand } from "./test.ts";
import type { CoverageOptions } from "./coverage.ts";

export async function retestCommand(
  databaseUrl: string,
  confirm: boolean = false,
  failFast = false,
  coverage?: CoverageOptions,
): Promise<void> {
  if (!confirm) {
    const answer = prompt(
      '⚠️  This will drop all database objects, re-run migrations, and execute tests. Type "yes" to continue:',
    );
    if (answer?.toLowerCase() !== "yes") {
      console.log("Aborted.");
      Deno.exit(0);
    }
  }

  console.log("Starting retest...");

  console.log("\n--- Step 1/3: dropall ---");
  await dropallCommand(databaseUrl, true, false);

  console.log("\n--- Step 2/3: migrate --apps nwind,test ---");
  await migrateCommand("nwind,test", databaseUrl, false);

  console.log("\n--- Step 3/3: test ---");
  await testCommand(databaseUrl, false, failFast, undefined, coverage);

  console.log("\nRetest completed successfully!");
}
