#!/usr/bin/env -S deno run --allow-net
/**
 * Hostile-client security check for the direct-OAuth deployment.
 *
 * Because clients connect DIRECTLY to Postgres (no PostgREST in between), an
 * authenticated session can try to overwrite request.jwt.claims to impersonate
 * a different user. A correct deployment must ignore that and keep the identity
 * Postgres actually validated (system_user = 'oauth:<sub>').
 *
 *   1. Authenticate via OAUTHBEARER as the real subject (default: user1).
 *   2. Confirm rbac.uid() reports that subject (honest baseline).
 *   3. ATTACK: overwrite request.jwt.claims to claim a different sub (user2).
 *   4. Assert rbac.uid() STILL reports the real subject.
 *
 * Exit 0 = secure (attack blocked). Exit 1 = vulnerable. Requires `_core`
 * deployed in the target database.
 *
 *   deno run --allow-net test_oauth_security.ts [--host..] [--port..] [--db..]
 *            [--real-sub user1] [--spoof-sub user2]
 */
import { mintToken, oauthConnect, parseFlags, runQuery } from "./verify_oauth.ts";

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  const realSub = a["real-sub"] ?? "user1";
  const spoofSub = a["spoof-sub"] ?? "user2";

  const token = await mintToken(realSub, a["client-id"] ?? "test-client");
  const conn = await oauthConnect(host, port, db, token);
  console.log(`authenticated via OAUTHBEARER as ${realSub}`);

  let baseline: string | null;
  try {
    baseline = (await runQuery(conn, "SELECT rbac.uid()"))[0][0];
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/rbac\.uid|schema "rbac"|does not exist/.test(msg)) {
      console.log(`SKIP: _core not deployed (rbac.uid() unavailable): ${msg}`);
      return 2;
    }
    throw e;
  }
  console.log(`baseline rbac.uid() = ${JSON.stringify(baseline)}  (expected "${realSub}")`);
  if (baseline !== realSub) {
    console.log("FAIL: honest identity wrong before attack");
    return 1;
  }

  // ---- attack: overwrite the claims to impersonate another subject ----------
  const spoof = `{"sub":"${spoofSub}","role":"authenticated"}`;
  await runQuery(conn, `SELECT set_config('request.jwt.claims', $$${spoof}$$, false)`);
  console.log(`ATTACK: client overwrote request.jwt.claims with sub="${spoofSub}"`);

  const after = (await runQuery(conn, "SELECT rbac.uid()"))[0][0];
  console.log(`rbac.uid() after attack = ${JSON.stringify(after)}`);
  conn.close();

  if (after === spoofSub) {
    console.log(`\nVULNERABLE: impersonation succeeded — rbac.uid() trusts the ` +
      `client-set claim, so the session now acts as "${spoofSub}" instead of "${realSub}".`);
    return 1;
  }
  if (after === realSub) {
    console.log(`\nSECURE: impersonation blocked — rbac.uid() kept the validated ` +
      `identity "${realSub}" (from system_user), ignoring the forged claim.`);
    return 0;
  }
  console.log(`\nUNEXPECTED: rbac.uid() returned ${JSON.stringify(after)}`);
  return 1;
}

if (import.meta.main) Deno.exit(await main());
