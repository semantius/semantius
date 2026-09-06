// =============================================================================
// list-users.ts — list users from a Semantius database with Kysely,
// authenticating via an OAuth token from the test OIDC server (PostgreSQL 18
// SASL OAUTHBEARER). The first Kysely sample; sibling files add more.
// =============================================================================
//
// The "raw" Kysely example: no generated types, just direct `sql\`…\`` execution.
//
// What it does, end to end:
//   1. Get an access token (./get-auth-token — mints a test token here; in a
//      real app you'd return the current user's session token instead).
//   2. Connect to PostgreSQL as the `authenticated` role, presenting that token
//      over SASL OAUTHBEARER (see ./kysely-dialect + ./pg-oauthbearer).
//   3. Call public.get_userinfo() once — first-login provisioning. It upserts
//      our user row and assigns the `User` role, which carries `user:read`. The
//      RLS SELECT policy on `users` requires `user:read`, so without this the
//      list would come back empty.
//   4. Run a direct SQL statement to list the users now visible under RLS.
//
// Run it (from this folder):
//   npm install
//   npx tsx src/list-users.ts   # run this sample
//   npm start                   # convenience alias for this first sample
//
// Point it at your stack with env vars (defaults in parentheses):
//   PGHOST (localhost)  PGPORT (5432)  PGDATABASE (appdb)
//   USER_ID (user3 = admin@test.com)  CLIENT_ID (test-client)  ISSUER (https://oidc-test.semanti.us)
//   (USER_ID / CLIENT_ID / ISSUER are read by ./get-auth-token.)
//
// For the EXTENSION stack (pg-ext-*), use PGPORT=5433. The CLI stack (5432)
// needs `_core` deployed first (deno task migrate --apps _core). Either way the
// container must be able to reach the issuer's HTTPS JWKS endpoint outbound.
// =============================================================================

import { Kysely, sql } from "kysely";
import { OAuthBearerDialect } from "./kysely-dialect";
import { getAuthToken } from "./get-auth-token";

const HOST = process.env.PGHOST ?? "localhost";
const PORT = Number(process.env.PGPORT ?? 5432);
const DATABASE = process.env.PGDATABASE ?? "appdb";
const USER_ID = process.env.USER_ID ?? "user3"; // for the summary line only (user3 = admin@test.com)

async function main(): Promise<void> {
  const token = await getAuthToken();

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
    // No type, `select *` — add a column to the table and it just shows up here.
    const users = await sql`
      select * from users order by id
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
