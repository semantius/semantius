#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read
/**
 * Trust-model + guardrail checks for SESSION mode (the Supabase/Neon model).
 *
 * This is the session-mode mirror of test_oauth_security.ts. The crucial
 * DIFFERENCE it documents: in bearer mode PostgreSQL pins the subject via
 * system_user ('oauth:<sub>'), so a client cannot impersonate. In session mode
 * there is NO such pin — `request.jwt.claims` is authoritative, so the APP is the
 * sole trust boundary (it MUST jose-verify the JWT before injecting). This is by
 * design, not a vulnerability; the test asserts it so the contract is explicit.
 *
 * Checks (all must pass):
 *   TRUST  inject sub=<spoof> -> rbac.uid() returns <spoof> (no system_user
 *          override in session mode; the injected claim is trusted).
 *   NEG-a  connect, no SET ROLE / no claims -> a privileged read is DENIED
 *          (NOINHERIT: the role has no privileges of its own).
 *   NEG-b  SET ROLE authenticated but inject NO claims -> rbac.uid() raises
 *          "Authentication required".
 *   NEG-c  inject claims with role != authenticated -> rbac.uid() is rejected.
 *
 * Exit 0 = all pass. Exit 2 = _core not deployed.
 *
 *   deno run --allow-net --allow-env --allow-read test_session_trust.ts \
 *     [--host..] [--port..] [--db..] [--real-sub user1] [--spoof-sub user2]
 */
import { parseFlags } from "./verify_oauth.ts";
import {
  claimsFor,
  connectAuthenticator,
  inSession,
  resolvePassword,
  scalar,
} from "./session_helpers.ts";

function notDeployed(msg: string): boolean {
  return /rbac\.uid|schema "rbac"|function .* does not exist/i.test(msg);
}

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  const realSub = a["real-sub"] ?? "user1";
  const spoofSub = a["spoof-sub"] ?? "user2";
  const password = await resolvePassword();

  const client = await connectAuthenticator({ host, port, db, password });
  console.log(
    `connected as semantius_authenticator (SCRAM) to ${host}:${port}/${db}`,
  );

  let pass = true;
  const ok = (label: string, good: boolean, detail: string) => {
    console.log(`${good ? "PASS" : "FAIL"}  ${label}: ${detail}`);
    if (!good) pass = false;
  };

  try {
    // ---- TRUST: injected claim is authoritative in session mode --------------
    try {
      const uid = await inSession(
        client,
        await claimsFor(spoofSub),
        () => scalar(client, "SELECT rbac.uid()"),
      );
      ok(
        "TRUST (app is the trust boundary)",
        uid === spoofSub,
        `injected sub="${spoofSub}" -> rbac.uid()="${uid}" ` +
          `(expected "${spoofSub}"; no system_user override in session mode)`,
      );
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (notDeployed(msg)) {
        console.log(`SKIP: _core not deployed (${msg})`);
        return 2;
      }
      throw e;
    }

    // ---- NEG-a: no SET ROLE / no claims -> privileged read denied (NOINHERIT) -
    {
      let denied = false, detail = "unexpectedly succeeded";
      try {
        await client.queryArray("SELECT count(*) FROM users");
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        denied = /permission denied|insufficient/i.test(msg);
        detail = msg.split("\n")[0];
      }
      ok("NEG-a (NOINHERIT blocks bare role)", denied, detail);
    }

    // ---- NEG-b: SET ROLE but no claims -> "Authentication required" ----------
    {
      let raised = false, detail = "unexpectedly returned a value";
      try {
        await client.queryArray("BEGIN");
        await client.queryArray("SET LOCAL ROLE authenticated");
        await client.queryArray("SELECT rbac.uid()");
        await client.queryArray("COMMIT");
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        raised = /authentication required/i.test(msg);
        detail = msg.split("\n")[0];
        await client.queryArray("ROLLBACK").catch(() => {});
      }
      ok("NEG-b (no claims rejected)", raised, detail);
    }

    // ---- NEG-c: role != authenticated -> rejected ---------------------------
    {
      let rejected = false, detail = "unexpectedly accepted";
      try {
        await inSession(
          client,
          { sub: realSub, role: "anon" },
          () => scalar(client, "SELECT rbac.uid()"),
        );
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        rejected = /authentication required|role claim/i.test(msg);
        detail = msg.split("\n")[0];
      }
      ok("NEG-c (bad role claim rejected)", rejected, detail);
    }

    console.log(
      pass
        ? "\nSESSION TRUST MODEL OK: app is the trust boundary; the role floor and rbac.uid() gates hold."
        : "\nFAIL: one or more session trust/negative checks did not behave as required.",
    );
    return pass ? 0 : 1;
  } finally {
    await client.end();
  }
}

if (import.meta.main) Deno.exit(await main());
