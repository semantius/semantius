/**
 * Shared helpers for the SESSION-mode verification scripts (verify_session.ts,
 * test_session_trust.ts).
 *
 * Session mode is the Supabase/Neon model: connect as the restricted login role
 * `semantius_authenticator` over SCRAM, then per transaction `SET LOCAL ROLE
 * authenticated` and inject the (already app-verified) JWT claims into
 * `request.jwt.claims`. The hand-rolled wire transport in verify_oauth.ts only
 * speaks OAUTHBEARER, so these scripts use a standard SCRAM driver — the
 * already-locked deno.land/x/postgres (SCRAM impl in deno.lock).
 *
 *   permissions: --allow-net --allow-env --allow-read   (read = pgdocker/.env)
 */
import { Client } from "https://deno.land/x/postgres@v0.17.0/mod.ts";
import { mintToken } from "./verify_oauth.ts";

export interface SessionTarget {
  host: string;
  port: number;
  db: string;
  password: string;
}

/**
 * Resolve the `semantius_authenticator` password, in order:
 *   1. $SEMANTIUS_AUTHENTICATOR_PASSWORD
 *   2. SEMANTIUS_AUTHENTICATOR_PASSWORD in pgdocker/.env (next to this script)
 *   3. the dev default "devpassword"
 * Mirrors what init/11-session-role.sh sets inside the container.
 */
export async function resolvePassword(): Promise<string> {
  const fromEnv = Deno.env.get("SEMANTIUS_AUTHENTICATOR_PASSWORD");
  if (fromEnv) return fromEnv;
  try {
    const envText = await Deno.readTextFile(new URL("./.env", import.meta.url));
    for (const line of envText.split(/\r?\n/)) {
      const m = line.match(
        /^\s*SEMANTIUS_AUTHENTICATOR_PASSWORD\s*=\s*(.*?)\s*$/,
      );
      if (m) return m[1].replace(/^["']|["']$/g, "");
    }
  } catch {
    // No readable .env — fall through to the dev default.
  }
  return "devpassword";
}

/** Open a SCRAM connection as `semantius_authenticator` (no TLS on localhost). */
export async function connectAuthenticator(t: SessionTarget): Promise<Client> {
  const client = new Client({
    user: "semantius_authenticator",
    password: t.password,
    database: t.db,
    hostname: t.host,
    port: t.port,
    tls: { enabled: false },
  });
  await client.connect();
  return client;
}

/**
 * Mint a token for `sub` from the test issuer and return its decoded payload as
 * the claims object to inject — the real claim shape (sub, email, iss, exp, ...).
 * `role` is forced to 'authenticated' to model the session contract: the role is
 * set server-side, never trusted from the token.
 */
export async function claimsFor(
  sub: string,
  clientId = "test-client",
): Promise<Record<string, unknown>> {
  const token = await mintToken(sub, clientId);
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error(`not a JWT: ${token.slice(0, 40)}`);
  const payload = JSON.parse(decodeB64Url(parts[1])) as Record<string, unknown>;
  payload.role = "authenticated";
  return payload;
}

function decodeB64Url(seg: string): string {
  const b64 = seg.replace(/-/g, "+").replace(/_/g, "/")
    .padEnd(Math.ceil(seg.length / 4) * 4, "=");
  const bin = atob(b64);
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

/**
 * The session-mode per-request contract: open a fresh transaction, `SET LOCAL
 * ROLE authenticated`, inject the claims (LOCAL, BEFORE any rbac call — rbac.uid()
 * is STABLE/cached per tx), run `fn`, then COMMIT. Rolls back on error so an
 * expected failure does not leave the connection in an aborted-tx state.
 */
export async function inSession<T>(
  client: Client,
  claims: Record<string, unknown>,
  fn: () => Promise<T>,
): Promise<T> {
  await client.queryArray("BEGIN");
  try {
    await client.queryArray("SET LOCAL ROLE authenticated");
    await client.queryArray({
      text: "SELECT set_config('request.jwt.claims', $1, true)",
      args: [JSON.stringify(claims)],
    });
    const result = await fn();
    await client.queryArray("COMMIT");
    return result;
  } catch (err) {
    await client.queryArray("ROLLBACK").catch(() => {});
    throw err;
  }
}

/** Convenience: single scalar (first column of first row) from a query. */
export async function scalar(
  client: Client,
  text: string,
  args: unknown[] = [],
): Promise<string | null> {
  const r = await client.queryArray<[unknown]>({ text, args });
  const v = r.rows[0]?.[0];
  return v === null || v === undefined ? null : String(v);
}
