// Throwaway probe: exercises getUserInfo() + listAuditRecords() through the REAL
// bearer (pg-proxy) adapter — the path the /users and /audit pages use.
import { decodeJwt } from "jose";
import { withSession } from "../lib/db/session";
import { getUserInfo, listAuditRecords } from "../lib/dal/users";
import type { SessionContext } from "../lib/db/adapter";

const ISSUER = "https://oidc-test.semanti.us";
const USER_ID = process.env.USER_ID ?? "user3";
const PORT = process.env.PORT ?? "5432";

async function mint(): Promise<string> {
  const url = `${ISSUER}/getaccesstoken?user_id=${USER_ID}&client_id=test-client`;
  const r = await fetch(url, { headers: { "user-agent": "curl/8.0", accept: "*/*" } });
  let body = (await r.text()).trim();
  if (body.startsWith("{")) body = JSON.parse(body).access_token ?? "";
  return body;
}

async function main() {
  const token = await mint();
  const decoded = decodeJwt(token);
  process.env.DB_AUTH_MODE = "bearer";
  process.env.OAUTH_ISSUER = ISSUER;
  process.env.PG_HOST = "localhost";
  process.env.PG_PORT = PORT;
  process.env.PG_DATABASE = "appdb";
  const ctx: SessionContext = {
    token,
    claims: { ...decoded, sub: String(decoded.sub ?? ""), role: "authenticated" },
  };
  const out = await withSession(ctx, async () => ({
    info: await getUserInfo(),
    audit: await listAuditRecords(5),
  }));
  console.log("getUserInfo:", JSON.stringify(out.info));
  console.log("audit rows:", out.audit.length, JSON.stringify(out.audit.slice(0, 2)));
}
main().then(() => process.exit(0)).catch((e) => {
  console.error("PROBE FAILED:", e instanceof Error ? e.stack : e);
  process.exit(1);
});
