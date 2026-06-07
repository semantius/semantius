// =============================================================================
// drizzle.config.ts — config for `drizzle-kit studio` (the data browser).
// =============================================================================
//
// IMPORTANT: Studio does NOT use the OAUTHBEARER transport this example uses at
// runtime. drizzle-kit only speaks the standard PostgreSQL drivers, configured
// through `dbCredentials` below — so Studio connects with a normal password
// connection string, as the `postgres` superuser.
//
// That role authenticates with SCRAM (see pgdocker/conf/pg_hba.conf) and, being
// a superuser, BYPASSES Row Level Security — which is what you want for a dev
// data browser (you see every row, not just those visible to one OAuth user).
// The OAUTHBEARER path (role `authenticated`, RLS-enforced) is only exercised by
// `npm start` / src/list-users.ts.
//
// Point DATABASE_URL at your stack's `postgres` login. Default below matches the
// local pgdocker CLI stack (port 5432). For the extension stack use port 5433.
// =============================================================================

import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/schema/index.ts",
  dbCredentials: {
    url: process.env.DATABASE_URL ??
      "postgresql://postgres:devpassword@localhost:5432/appdb",
  },
});
