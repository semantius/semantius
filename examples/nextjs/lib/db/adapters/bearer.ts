// =============================================================================
// bearer adapter — PostgreSQL 18 native OAuth (SASL OAUTHBEARER).
//
// The end-user's bearer token authenticates the DB connection; pg_oidc_validator
// verifies the RS256 signature IN THE DATABASE and publishes request.jwt.claims,
// and PostgreSQL pins identity via system_user (= 'oauth:<sub>'). So there is NO
// app-side claim injection here — the DB is the trust boundary.
//
// Caveats (see plan / README "Scalability"):
//   - ONE connection per request, no pool: an OAUTHBEARER connection is bound to
//     one `sub` and cannot be shared across users, and PgBouncer can't passthrough
//     it. Demo / low-concurrency self-host only.
//   - pg-proxy has no db.transaction(); we wrap each request in a manual
//     BEGIN/COMMIT (ROLLBACK on error) serialized over the transport — uniform
//     with the session path and pooler-safe.
//   - ALWAYS .end() the connection in finally, or the socket leaks (no pool).
// =============================================================================

import { createDb } from "../drizzle-proxy";
import { PgOAuthConnection } from "../pg-oauthbearer";
import type { DbAdapter, SessionContext } from "../adapter";
import type { DbHandle } from "../types";
import { optionalEnv, requireEnv } from "../env";

export function createBearerAdapter(): DbAdapter {
  const host = requireEnv("PG_HOST");
  const port = Number(optionalEnv("PG_PORT", "5432"));
  const database = requireEnv("PG_DATABASE");

  return {
    mode: "bearer",

    async runInSession<T>(
      ctx: SessionContext,
      fn: (db: DbHandle) => Promise<T>,
    ): Promise<T> {
      const conn = await PgOAuthConnection.connect({
        host,
        port,
        database,
        token: ctx.token,
      });
      const db = createDb(conn) as DbHandle;
      try {
        await conn.query("BEGIN");
        try {
          const result = await fn(db);
          await conn.query("COMMIT");
          return result;
        } catch (err) {
          await conn.query("ROLLBACK").catch(() => {});
          throw err;
        }
      } finally {
        await conn.end();
      }
    },
  };
}
