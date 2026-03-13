/**
 * Semantius migration task for TriggerDev.
 *
 * This file is the entry point for TriggerDev. It re-exports the
 * `migrationTask` from the @semantius/triggerdev library.
 *
 * Deploy with:
 *   cd packages/triggerdev
 *   npx trigger.dev@latest deploy
 *
 * Trigger from your application:
 *   import { tasks } from "@trigger.dev/sdk/v3";
 *
 *   // Run _core migrations only
 *   await tasks.trigger("run-migrations", {
 *     databaseUrl: process.env.DATABASE_URL!,
 *     modules: ["_core"],
 *   });
 *
 *   // Run _core + nwind migrations
 *   await tasks.trigger("run-migrations", {
 *     databaseUrl: process.env.DATABASE_URL!,
 *     modules: ["_core", "nwind"],
 *   });
 *
 *   // Run all bundled migrations
 *   await tasks.trigger("run-migrations", {
 *     databaseUrl: process.env.DATABASE_URL!,
 *   });
 */

export { migrationTask } from "../src/index.js";
