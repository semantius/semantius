// =============================================================================
// kysely-direct.ts — list users from Semantius core with Kysely, authenticating
// via an OAuth token from the test OIDC server (PostgreSQL 18 SASL OAUTHBEARER).
// =============================================================================
//
// What it does, end to end:
//   1. Mint a fresh access token for a test user from the test OIDC issuer
//      (no interactive login — the test server mints tokens for anyone).
//   2. Connect to PostgreSQL as the `authenticated` role, presenting that token
//      over SASL OAUTHBEARER (see ./kysely-dialect + ./pg-oauthbearer).
//   3. Call public.get_userinfo() once — first-login provisioning. It upserts
//      our user row and assigns the `User` role, which carries `user:read`. The
//      RLS SELECT policy on `users` requires `user:read`, so without this the
//      list would come back empty.
//   4. Run a direct SQL statement to list the users now visible under RLS.
//
// Run it:
//   npm install
//   npm start
//
// Point it at your stack with env vars (defaults in parentheses):
//   PGHOST (localhost)  PGPORT (5432)  PGDATABASE (appdb)
//   USER_ID (user1)     CLIENT_ID (test-client)
//   ISSUER (https://oidc-test.semanti.us)
//
// For the EXTENSION stack (pg-ext-*), use PGPORT=5433. The CLI stack (5432)
// needs `_core` deployed first (deno task migrate --apps _core). Either way the
// container must be able to reach the issuer's HTTPS JWKS endpoint outbound.
// =============================================================================

import { Kysely, sql } from "kysely";
import { OAuthBearerDialect } from "./kysely-dialect";

// TEST ISSUER ONLY — a public, throwaway OIDC server that mints tokens for
// anyone with no login. It holds no secrets; it exists only to exercise the
// OAuth path. Replace with your own trusted issuer for anything real (and keep
// it in sync with the issuer= line in pgdocker/conf/pg_hba.conf).
const ISSUER = process.env.ISSUER ?? "https://oidc-test.semanti.us";
const HOST = process.env.PGHOST ?? "localhost";
const PORT = Number(process.env.PGPORT ?? 5432);
const DATABASE = process.env.PGDATABASE ?? "appdb";
const USER_ID = process.env.USER_ID ?? "user1";
const CLIENT_ID = process.env.CLIENT_ID ?? "test-client";

/** Shape of a row from the `users` table (the columns we select). */
interface UserRow {
  id: string;
  external_id: string;
  email: string;
  display_name: string;
  last_seen: string | null;
}

/** Mint an access token for a test user from the test OIDC server. */
async function mintToken(userId: string, clientId: string): Promise<string> {
  const url = `${ISSUER}/getaccesstoken?user_id=${encodeURIComponent(
    userId,
  )}&client_id=${encodeURIComponent(clientId)}`;
  const res = await fetch(url, {
    headers: { "user-agent": "curl/8.0", accept: "*/*" },
  });
  if (!res.ok) throw new Error(`token mint failed: HTTP ${res.status}`);
  let body = (await res.text()).trim();
  if (body.startsWith("{")) body = JSON.parse(body).access_token ?? "";
  if (body.split(".").length !== 3) {
    throw new Error(`issuer did not return a JWT (got: ${body.slice(0, 60)}…)`);
  }
  return body;
}

async function main(): Promise<void> {
  console.log(`Minting token for "${USER_ID}" from ${ISSUER} …`);
  const token = await mintToken(USER_ID, CLIENT_ID);

  // `Kysely<any>` because we use raw `sql` statements (no schema definition
  // needed — that's the point of starting with Kysely rather than Drizzle).
  const db = new Kysely<any>({
    dialect: new OAuthBearerDialect({
      host: HOST,
      port: PORT,
      database: DATABASE,
      token,
    }),
  });

  try {
    // Prove who we are on the wire. `system_user` is `oauth:<sub>` — the
    // identity PostgreSQL validated from the bearer token against the issuer's
    // JWKS; a client cannot forge it.
    const who = await sql<{ current_user: string; system_user: string }>`
      select current_user, system_user
    `.execute(db);
    console.log("Connected:", who.rows[0]);

    // First-login provisioning (assigns the User role -> user:read).
    await sql`select public.get_userinfo()`.execute(db);

    // The goal: a list of users via a direct SQL statement, returned under RLS.
    const users = await sql<UserRow>`
      select id, external_id, email, display_name, last_seen
      from users
      order by id
    `.execute(db);

    console.log();
    console.table(users.rows);
    console.log(`\n${users.rows.length} user(s) visible to "${USER_ID}" under RLS.`);
  } finally {
    await db.destroy();
  }
}

main().catch((err) => {
  console.error("FAILED:", err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
