import { Hono } from "hono";
import type { Bindings } from "../types.js";
import { migrate } from "../migrate.js";

const route = new Hono<{ Bindings: Bindings }>();

/**
 * POST /migrate
 *
 * Accepts a JSON body with:
 *   - database_url: string (required)
 *   - modules: string[]   (optional, defaults to all bundled apps)
 *
 * Returns JSON with migration result.
 */
route.post("/", async (c) => {
  let body: { database_url?: string; modules?: string[] };

  try {
    body = await c.req.json();
  } catch {
    return c.json({ success: false, error: "Invalid JSON body" }, 400);
  }

  const databaseUrl = body.database_url;

  if (!databaseUrl) {
    return c.json(
      {
        success: false,
        error: "database_url must be provided in the request body",
      },
      400,
    );
  }

  try {
    const result = await migrate(databaseUrl, body.modules, { verbose: true });
    return c.json(result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return c.json({ success: false, error: message }, 500);
  }
});

export default route;
