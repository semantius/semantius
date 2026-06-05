#!/usr/bin/env -S deno run --allow-net
/**
 * Call public.get_userinfo() for a given JWT and print the result.
 *
 *   deno run --allow-net get_userinfo_jwt.ts <jwt> [--host 127.0.0.1]
 *            [--port 5432] [--db appdb]
 *
 * Authenticates to Postgres via SASL OAUTHBEARER presenting <jwt> (so the server
 * validates it against the issuer's JWKS and publishes its claims), then runs
 * SELECT public.get_userinfo(). Prints:
 *   - the returned user-info JSON on success,
 *   - the database / auth error on failure (bad or expired token, _core not
 *     deployed, RLS rejection, ...),
 *   - a usage notice (exit 2) when no JWT was given on the command line.
 */
import { oauthConnect, runQuery } from "./verify_oauth.ts";

function parse(argv: string[]) {
  const o = { jwt: undefined as string | undefined, host: "127.0.0.1", port: 5432, db: "appdb" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--host") o.host = argv[++i];
    else if (a === "--port") o.port = Number(argv[++i]);
    else if (a === "--db") o.db = argv[++i];
    else if (!a.startsWith("--") && o.jwt === undefined) o.jwt = a;
  }
  return o;
}

async function main(): Promise<number> {
  const { jwt, host, port, db } = parse(Deno.args);

  if (!jwt) {
    console.error("No JWT given on the command line.");
    console.error("Usage: get-userinfo-jwt <jwt> [--host 127.0.0.1] [--port 5432] [--db appdb]");
    return 2;
  }

  let conn: Deno.Conn | undefined;
  try {
    conn = await oauthConnect(host, port, db, jwt);
    const raw = (await runQuery(conn, "SELECT public.get_userinfo()"))[0]?.[0];
    if (raw == null) {
      console.log("get_userinfo() returned NULL");
    } else {
      try {
        console.log(JSON.stringify(JSON.parse(raw), null, 2));
      } catch {
        console.log(raw); // not JSON — print as-is
      }
    }
    return 0;
  } catch (e) {
    console.error(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  } finally {
    conn?.close();
  }
}

if (import.meta.main) Deno.exit(await main());
