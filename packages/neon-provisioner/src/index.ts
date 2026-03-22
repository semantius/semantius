/**
 * @semantius/neon-provisioner - Hono server for Cloudflare Workers
 *
 * Routes:
 *   POST /migrate           — Run database migrations
 *   POST /neon-provisioner  — Full Neon provisioning: project, JWKS, migration, data API
 *   POST /refresh_cache     — Reset Neon Data API cache and update _settings cache_version
 */

import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
import type { Bindings } from "./types.js";
import migrateRoute from "./routes/migrate.js";
import neonProvisionerRoute from "./routes/neon-provisioner.js";
import refreshCacheRoute from "./routes/refresh-cache.js";

const app = new Hono<{ Bindings: Bindings }>();

// Require NEON_PROVISIONER_API_KEY on API routes (static assets are served without auth)
const requireApiKey: MiddlewareHandler<{ Bindings: Bindings }> = async (c, next) => {
  const provisionerKey = c.env?.NEON_PROVISIONER_API_KEY;
  if (!provisionerKey) {
    return c.json(
      {
        success: false,
        error: "Service misconfigured: NEON_PROVISIONER_API_KEY environment variable is not set",
      },
      500,
    );
  }
  const authHeader = c.req.header("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return c.json({ success: false, error: "Unauthorized: missing Bearer token" }, 401);
  }
  const token = authHeader.slice(7);
  // Use constant-time byte comparison to prevent timing attacks
  const enc = new TextEncoder();
  const a = enc.encode(token);
  const b = enc.encode(provisionerKey);
  let mismatch = a.byteLength !== b.byteLength ? 1 : 0;
  const len = Math.min(a.byteLength, b.byteLength);
  for (let i = 0; i < len; i++) {
    mismatch |= a[i] ^ b[i];
  }
  if (mismatch !== 0) {
    return c.json({ success: false, error: "Unauthorized: invalid API key" }, 401);
  }
  return next();
};

app.use("/migrate", requireApiKey);
app.use("/neon-provisioner", requireApiKey);
app.use("/refresh_cache", requireApiKey);

app.route("/migrate", migrateRoute);
app.route("/neon-provisioner", neonProvisionerRoute);
app.route("/refresh_cache", refreshCacheRoute);

export default app;
