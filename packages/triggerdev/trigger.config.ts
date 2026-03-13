import { defineConfig } from "@trigger.dev/sdk/v3";

/**
 * TriggerDev configuration for @semantius/triggerdev.
 *
 * Required environment variables (set in .env.local or TriggerDev project settings):
 *   DATABASE_URL        — PostgreSQL connection URL
 *   TRIGGER_SECRET_KEY  — TriggerDev API secret key
 *   TRIGGER_PROJECT_ID  — TriggerDev project ID
 *
 * Before deploying, run the build step to bundle SQL migrations and compile TypeScript:
 *   pnpm run triggerdev:build   (from repo root)
 *
 * Then deploy from this directory:
 *   npx trigger.dev@latest deploy
 */
export default defineConfig({
  project: process.env.TRIGGER_PROJECT_ID ?? "",
  dirs: ["./trigger"],
  retries: {
    enabledInDev: false,
    default: {
      maxAttempts: 3,
      minTimeoutInMs: 1000,
      maxTimeoutInMs: 10000,
      factor: 2,
      randomize: true,
    },
  },
});
