// =============================================================================
// Hono resource-server entry point.
//
// Middleware chain (ORDER MATTERS):
//   1. CORS            exact-match allowlist; bearer model needs no cookies, so
//                      credentials:false. Hono's cors short-circuits the OPTIONS
//                      preflight BEFORE auth (preflights carry no Authorization).
//   2. contextStorage  AsyncLocalStorage for Hono's request context (ambient `c`).
//   3. sessionMiddleware  (applied per data route, see routes/users.ts) — verify /
//                      forward the token, open ONE request-scoped transaction,
//                      inject claims, run the handler under RLS.
//
// Run with: npm run dev  (tsx watch). Node runtime is required — node-postgres and
// the OAUTHBEARER transport need raw TCP (Workers can't, without Hyperdrive/neon-http).
// =============================================================================

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { contextStorage } from "hono/context-storage";
import { data } from "./routes/users";
import { getAdapter } from "../lib/db/session";
import type { AppEnv } from "./middleware/session";

// Load .env from the package root (one level up from src/), regardless of the
// process cwd (Node ≥20.12). Env may also be provided externally.
try {
  process.loadEnvFile(join(dirname(fileURLToPath(import.meta.url)), "..", ".env"));
} catch {
  // no .env file — fall back to the ambient environment.
}

const PORT = Number(process.env.PORT ?? "8788");
const CORS_ORIGINS = (process.env.CORS_ORIGINS ?? "http://localhost:3000")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const app = new Hono<AppEnv>();

// 1. CORS — exact-match allowlist (Hono reflects the request Origin only if it's in
//    the array, never '*'). Allow the Authorization header + the write's PUT method
//    (which triggers a preflight). No cookies → no CSRF surface.
app.use(
  "*",
  cors({
    origin: CORS_ORIGINS,
    allowHeaders: ["Authorization", "Content-Type"],
    allowMethods: ["GET", "POST", "PUT", "OPTIONS"],
    credentials: false,
    maxAge: 600,
  }),
);

// 2. contextStorage — ambient access to the Hono context for deep call-stack code.
app.use("*", contextStorage());

// Public info / health (no auth, no DB).
app.get("/", (c) =>
  c.json({
    name: "@semantius/example-spa-hono-backend",
    mode: process.env.DB_AUTH_MODE ?? "bearer",
    endpoints: ["GET /me", "GET /users", "PUT /me/display-name"],
  }),
);

// 3. Data routes (each wrapped by sessionMiddleware → auth + request-scoped tx).
app.route("/", data);

app.onError((err, c) => {
  console.error("[error]", err instanceof Error ? err.stack : err);
  return c.json(
    { error: "internal_error", message: err instanceof Error ? err.message : String(err) },
    500,
  );
});

async function main(): Promise<void> {
  // Startup guardrail: in session mode this refuses a superuser/owner connection
  // (the silent-RLS-bypass trap) BEFORE serving. No-op in bearer mode.
  await getAdapter().init?.();

  serve({ fetch: app.fetch, port: PORT }, (info) => {
    console.log(
      `spa-hono-backend listening on http://localhost:${info.port} ` +
        `(DB_AUTH_MODE=${process.env.DB_AUTH_MODE ?? "bearer"}, CORS=${CORS_ORIGINS.join(",")})`,
    );
  });
}

main().catch((err) => {
  console.error("failed to start:", err instanceof Error ? err.stack : err);
  process.exit(1);
});
