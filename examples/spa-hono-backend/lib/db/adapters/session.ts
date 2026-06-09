// =============================================================================
// session adapter — the Supabase / Neon / local model.
//
// Connects as the restricted login role `semantius_authenticator` (NOSUPERUSER
// NOINHERIT NOBYPASSRLS) over a normal node-postgres Pool, then per request, in a
// transaction:
//     SET LOCAL ROLE authenticated;
//     SELECT set_config('request.jwt.claims', <verified-payload>, true);
// i.e. it SET ROLEs into `authenticated` exactly like Supabase's
// `authenticator -> authenticated`. The app already verified the JWT (lib/db/
// verify.ts) — it is the SOLE trust boundary; the DB does not verify the
// signature in this mode.
//
// MANDATORY security requirements honoured here (foundation contract):
//   1. Verify before inject, fail closed   -> done upstream (verify.ts); only
//      verified claims ever reach this adapter.
//   2. Inject the EXACT verified payload    -> JSON.stringify(ctx.claims); role is
//      pinned 'authenticated' (set server-side, never trusted from the token).
//   3. Only inside a transaction            -> injection runs INSIDE db.transaction;
//      we never use session-level SET ROLE / set_config(..., false).
//   4. Refuse a superuser/owner connection  -> assertNotSuperuser() at startup.
//
// Transaction-pooler safety (Supabase 6543 / Neon): node-postgres uses UNNAMED
// extended-protocol statements by default — so NO `name:` on queries and NO
// Drizzle .prepare(). (`prepare: false` is a postgres.js option, not node-postgres;
// it would do nothing here.)
// =============================================================================

import { sql } from "drizzle-orm";
import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import * as schema from "../schema";
import type { DbAdapter, SessionContext } from "../adapter";
import type { DbHandle, Schema } from "../types";
import { optionalEnv, requireEnv } from "../env";

export function createSessionAdapter(): DbAdapter {
  const connectionString = requireEnv("DATABASE_URL");
  // Keep the pool SMALL behind a transaction pooler (Supabase 6543 / Neon) and on
  // serverless — see README "Scalability". Override with PG_POOL_MAX.
  const max = Number(optionalEnv("PG_POOL_MAX", "10"));

  let pool: Pool | null = null;
  let db: NodePgDatabase<Schema> | null = null;
  let guard: Promise<void> | null = null;

  function ensurePool(): { pool: Pool; db: NodePgDatabase<Schema> } {
    if (!pool || !db) {
      pool = new Pool({ connectionString, max, idleTimeoutMillis: 30_000 });
      db = drizzle(pool, { schema });
    }
    return { pool, db };
  }

  // Startup guardrail: a DATABASE_URL accidentally pointing at postgres/owner is
  // effectively superuser and SILENTLY BYPASSES RLS (returns every row). Refuse to
  // run if the connection role is SUPERUSER or BYPASSRLS. Memoized; a failure
  // clears the memo so a corrected env can retry.
  function assertNotSuperuser(): Promise<void> {
    if (!guard) {
      guard = (async () => {
        const { pool } = ensurePool();
        const { rows } = await pool.query<{ rolsuper: boolean; rolbypassrls: boolean }>(
          "select rolsuper, rolbypassrls from pg_roles where rolname = current_user",
        );
        const r = rows[0];
        if (!r) {
          throw new Error("session adapter: could not read current_user role attributes");
        }
        if (r.rolsuper || r.rolbypassrls) {
          throw new Error(
            "session adapter refuses to start: the connection role is SUPERUSER or BYPASSRLS " +
              "— it would silently bypass RLS and return every row. Connect as " +
              "semantius_authenticator, NEVER the postgres/owner connection string.",
          );
        }
      })().catch((err) => {
        guard = null;
        throw err;
      });
    }
    return guard;
  }

  return {
    mode: "session",
    init: assertNotSuperuser,

    async runInSession<T>(
      ctx: SessionContext,
      fn: (db: DbHandle) => Promise<T>,
    ): Promise<T> {
      await assertNotSuperuser();
      const { db } = ensurePool();
      const claimsJson = JSON.stringify(ctx.claims);

      // db.transaction pins ONE pooled client and wraps BEGIN/COMMIT/ROLLBACK.
      // Claims-first: rbac.uid() is STABLE/cached per tx, so SET ROLE + inject must
      // precede any rbac/RLS call inside fn.
      return db.transaction(async (tx) => {
        await tx.execute(sql`set local role authenticated`);
        await tx.execute(
          sql`select set_config('request.jwt.claims', ${claimsJson}, true)`,
        );
        return fn(tx as DbHandle);
      });
    },

    async close() {
      await pool?.end();
      pool = null;
      db = null;
      guard = null;
    },
  };
}
