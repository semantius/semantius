// Proves the session adapter REFUSES a superuser/owner connection at startup
// (the silent-RLS-bypass trap). Points DATABASE_URL at `postgres` (superuser) and
// asserts init() throws.
//
//   npx tsx scripts/smoke-guard.ts
//
// Env: PORT=5433  PGDATABASE=appdb  POSTGRES_PASSWORD=devpassword

const PORT = process.env.PORT ?? "5433";
const DB = process.env.PGDATABASE ?? "appdb";
const PW = process.env.POSTGRES_PASSWORD ?? "devpassword";

process.env.DB_AUTH_MODE = "session";
process.env.DATABASE_URL = `postgresql://postgres:${PW}@localhost:${PORT}/${DB}`;

const { createSessionAdapter } = await import("../lib/db/adapters/session");

const adapter = createSessionAdapter();
try {
  await adapter.init!();
  console.error("FAILED: adapter accepted a SUPERUSER connection (RLS would be bypassed!)");
  await adapter.close?.();
  process.exit(1);
} catch (err) {
  console.log("OK — guard fired:", err instanceof Error ? err.message : err);
  await adapter.close?.();
  process.exit(0);
}
