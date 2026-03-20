import { Hono } from "hono";
import type { Bindings } from "../types.js";
import { patchDataApi } from "../neon-api.js";
import { Pool } from "@neondatabase/serverless";

const route = new Hono<{ Bindings: Bindings }>();

/**
 * POST /refresh_cache
 *
 * Resets the Neon Data API cache for a specific database, then updates the
 * cache_version setting in the _settings table so downstream consumers know
 * the cache has been refreshed.
 *
 * Accepts JSON body:
 *   - project_id:    string  (required)
 *   - branch_id:     string  (required)
 *   - database_name: string  (required)
 *   - database_url:  string  (required)
 *
 * Returns JSON with success status and cache_reset_ts on success.
 */
route.post("/", async (c) => {
  let body: {
    project_id?: string;
    branch_id?: string;
    database_name?: string;
    database_url?: string;
  };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const { project_id, branch_id, database_name, database_url } = body;

  if (!project_id || !branch_id || !database_name || !database_url) {
    return c.json(
      {
        success: false,
        error: "project_id, branch_id, database_name, and database_url are all required",
      },
      400,
    );
  }

  const apiKey = c.env?.NEON_API_KEY;

  if (!apiKey) {
    return c.json(
      {
        success: false,
        error: "NEON_API_KEY environment variable must be set",
      },
      500,
    );
  }

  const cache_reset_ts = new Date().toISOString().replace(/(\.\d{3})Z$/, "$1000+00:00");

  try {
    // Step 1: PATCH the Neon Data API to trigger cache reset
    await patchDataApi(project_id, branch_id, database_name, { apiKey });

    // Step 2: Connect to the database and update _settings cache_version
    const pool = new Pool({ connectionString: database_url });
    try {
      await pool.query(
        `INSERT INTO _settings (name, value) VALUES ('cache_version', $1)
         ON CONFLICT (name) DO UPDATE SET value = $1`,
        [JSON.stringify(cache_reset_ts)],
      );
    } finally {
      await pool.end();
    }

    return c.json({ success: true, cache_reset_ts });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

export default route;
