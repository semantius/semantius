#!/usr/bin/env -S deno run --allow-net --allow-read
/**
 * Mint and print a JWT access token for a user from the test OIDC server, plus a
 * short note on how to present it.
 *
 *   deno run --allow-net --allow-read get_user_token.ts <user-name> [--client-id test-client]
 *
 * The JWT goes to STDOUT (so `TOKEN=$(get-user-token <user>)` works); the usage
 * note goes to STDERR (shown when you run it, ignored when you capture). Errors:
 * no token returned -> exit 1; no user name -> usage, exit 2. The issuer is the
 * one configured in verify_oauth.ts; the DB port / name shown are read from
 * ./.env (POSTGRES_*), falling back to defaults.
 */
import { mintToken } from "./verify_oauth.ts";

function parse(argv: string[]) {
  const o = { user: undefined as string | undefined, clientId: "test-client" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--client-id") o.clientId = argv[++i];
    else if (!a.startsWith("--") && o.user === undefined) o.user = a;
  }
  return o;
}

async function readEnv(): Promise<Record<string, string>> {
  try {
    const text = await Deno.readTextFile(new URL("./.env", import.meta.url));
    const out: Record<string, string> = {};
    for (const line of text.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const eq = t.indexOf("=");
      if (eq < 0) continue;
      out[t.slice(0, eq).trim()] = t.slice(eq + 1).trim().replace(/^["']|["']$/g, "");
    }
    return out;
  } catch {
    return {}; // no .env (e.g. before pg-cli-create.sh) — fall back to defaults
  }
}

async function main(): Promise<number> {
  const { user, clientId } = parse(Deno.args);

  if (!user) {
    console.error("No user name given on the command line.");
    console.error("Usage: get-user-token <user-name> [--client-id test-client]");
    return 2;
  }

  let token: string;
  try {
    token = await mintToken(user, clientId);
  } catch (e) {
    console.error(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }

  if (!token || token.split(".").length !== 3) {
    console.error(`error: no token returned for user "${user}"`);
    return 1;
  }

  // The token itself -> stdout (capturable / pipeable).
  console.log(token);

  // Connection cheat-sheet -> stderr (visible when run, ignored when captured).
  const env = await readEnv();
  const db = env.POSTGRES_DB || "appdb";
  const port = env.POSTGRES_PORT || "5432";
  console.error([
    "",
    `To act AS "${user}" (Postgres role 'authenticated', RLS-enforced):`,
    "  present the JWT above over SASL OAUTHBEARER. psql/pgAdmin support OAuth, but",
    "  only the interactive flow (they fetch their OWN token from the issuer) — libpq",
    "  has no parameter to inject a pre-minted token. So use a client that presents it:",
    `    ./get-userinfo-jwt.sh "<the token above>"     # or your app's OAUTHBEARER driver`,
    `    params: host=localhost port=${port} dbname=${db} user=authenticated  +  Bearer <token>`,
  ].join("\n"));
  return 0;
}

if (import.meta.main) Deno.exit(await main());
