// =============================================================================
// smoke-db.ts — headless validation of BOTH db adapters against a live pgdocker
// stack, WITHOUT a browser OAuth flow. Proves:
//   - bearer  : the end-user's token authenticates the connection via SASL
//               OAUTHBEARER and the DB validates it (PG18).
//   - session : the app connects as semantius_authenticator over SCRAM (NO
//               OAUTHBEARER), verifies the JWT itself (jose), and injects claims.
// Both then provision (get_userinfo) and read `users` under RLS.
//
//   npx tsx scripts/smoke-db.ts bearer
//   npx tsx scripts/smoke-db.ts session
//
// Env (defaults target the local EXT stack on 5433):
//   PORT=5433  PGDATABASE=appdb  USER_ID=user3  CLIENT_ID=test-client  (user3 = admin@test.com)
//   ISSUER=https://oidc-test.semanti.us
//   SEMANTIUS_AUTHENTICATOR_PASSWORD=devpassword   (session mode)
//
// A throwaway test harness — it bypasses the cookie/OAuth tier on purpose and
// mints a token the same way the other examples do (the /getaccesstoken shortcut).
// =============================================================================

import { decodeJwt } from "jose";
import { withSession } from "../lib/db/session";
import { verifyAccessToken } from "../lib/db/verify";
import { getUserByExternalId, listUsers, provisionCurrentUser } from "../lib/dal/users";
import type { SessionContext } from "../lib/db/adapter";

const mode = process.argv[2];
if (mode !== "bearer" && mode !== "session") {
  console.error("usage: tsx scripts/smoke-db.ts <bearer|session>");
  process.exit(2);
}

const ISSUER = process.env.ISSUER ?? "https://oidc-test.semanti.us";
const PORT = process.env.PORT ?? "5433";
const DB = process.env.PGDATABASE ?? "appdb";
// Default to the admin@test.com account (its issuer handle is `user3`; the issuer
// rejects the email as a user_id). Provisioning it first makes admin@test.com the
// Administrator, so the write demo and audit log work as the admin.
const USER_ID = process.env.USER_ID ?? "user3";
const CLIENT_ID = process.env.CLIENT_ID ?? "test-client";

async function mintToken(): Promise<string> {
  const url = `${ISSUER}/getaccesstoken?user_id=${encodeURIComponent(USER_ID)}&client_id=${encodeURIComponent(CLIENT_ID)}`;
  const res = await fetch(url, { headers: { "user-agent": "curl/8.0", accept: "*/*" } });
  if (!res.ok) throw new Error(`token mint failed: HTTP ${res.status}`);
  let body = (await res.text()).trim();
  if (body.startsWith("{")) body = JSON.parse(body).access_token ?? "";
  if (body.split(".").length !== 3) throw new Error(`issuer did not return a JWT: ${body.slice(0, 60)}…`);
  return body;
}

async function main(): Promise<void> {
  const token = await mintToken();
  const decoded = decodeJwt(token);
  console.log(
    `minted: sub=${decoded.sub} aud=${JSON.stringify(decoded.aud)} iss=${decoded.iss} role=${String((decoded as Record<string, unknown>).role)}`,
  );

  process.env.OAUTH_ISSUER = ISSUER;

  let ctx: SessionContext;
  if (mode === "bearer") {
    process.env.DB_AUTH_MODE = "bearer";
    process.env.PG_HOST = "localhost";
    process.env.PG_PORT = PORT;
    process.env.PG_DATABASE = DB;
    // bearer ignores claims (DB is authoritative); decode only for the lookup.
    ctx = { token, claims: { ...decoded, sub: String(decoded.sub ?? ""), role: "authenticated" } };
  } else {
    process.env.DB_AUTH_MODE = "session";
    const pw = process.env.SEMANTIUS_AUTHENTICATOR_PASSWORD ?? "devpassword";
    process.env.DATABASE_URL = `postgresql://semantius_authenticator:${pw}@localhost:${PORT}/${DB}`;
    process.env.OAUTH_JWKS_URI = `${ISSUER}/jwks`;
    const aud = Array.isArray(decoded.aud) ? decoded.aud[0] : decoded.aud;
    if (!aud) throw new Error("minted token has no `aud` — cannot exercise the mandatory aud check");
    process.env.OAUTH_EXPECTED_AUD = String(aud);
    // The real session path: verify the signature/iss/aud (jose) before injecting.
    const verified = await verifyAccessToken(token);
    console.log("session: jose RS256/iss/aud verification PASSED");
    ctx = { token, claims: verified };
  }

  const result = await withSession(ctx, async () => {
    await provisionCurrentUser();
    const me = await getUserByExternalId(ctx.claims.sub);
    const rows = await listUsers();
    return { me, rows };
  });

  console.log(`\n[${mode}] OK — provisioned + read under RLS (port ${PORT}, db ${DB})`);
  console.log(`  me: ${result.me ? `${result.me.email} (id=${result.me.id}, name="${result.me.displayName}")` : "(not found)"}`);
  console.log(`  users visible to ${ctx.claims.sub}: ${result.rows.length}`);
  console.table(
    result.rows.slice(0, 5).map((u) => ({ id: u.id, email: u.email, displayName: u.displayName })),
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(`\n[${mode}] FAILED:`, err instanceof Error ? err.stack : err);
    process.exit(1);
  });
