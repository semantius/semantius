#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read
/**
 * Verify the SESSION auth path end to end (the Supabase/Neon model).
 *
 *   1. Connect as the restricted login role `semantius_authenticator` over SCRAM.
 *   2. Guardrail: prove the role is powerless (NOT superuser, NOT bypassrls) —
 *      the same check a real session adapter must run at startup to refuse an
 *      accidentally-superuser/owner connection that would silently bypass RLS.
 *   3. First-login provisioning via the session path: in a tx, SET LOCAL ROLE
 *      authenticated + inject claims, then call public.get_userinfo() to create
 *      the user row (idempotent upsert).
 *   4. Positive RLS path: in a fresh tx, inject claims and assert rbac.uid()
 *      returns the subject and an RLS-protected read succeeds.
 *
 * Unlike bearer mode, NOTHING in the DB verifies the JWT signature here — the app
 * is the trust boundary (it would jose-verify before injecting). This script
 * mints from the test issuer and injects the decoded payload to exercise the
 * mechanism with a real claim shape.
 *
 * Exit 0 = ok. Exit 2 = _core not deployed (rbac.uid()/get_userinfo() missing).
 *
 *   deno run --allow-net --allow-env --allow-read verify_session.ts \
 *     [--host 127.0.0.1] [--port 5432] [--db appdb] [--user-id user3]
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
  return /rbac\.uid|get_userinfo|schema "rbac"|does not exist|function .* does not exist/i
    .test(msg);
}

async function main(): Promise<number> {
  const a = parseFlags(Deno.args);
  const host = a.host ?? "127.0.0.1";
  const port = Number(a.port ?? 5432);
  const db = a.db ?? "appdb";
  // Default to the admin@test.com account. At this issuer that account's handle is
  // `user3` (sub=user3, email=admin@test.com); the issuer rejects the email itself
  // as a user_id. Provisioning this first makes admin@test.com the Administrator.
  const sub = a["user-id"] ?? "user3";
  const password = await resolvePassword();

  const client = await connectAuthenticator({ host, port, db, password });
  console.log(
    `connected as semantius_authenticator (SCRAM) to ${host}:${port}/${db}`,
  );

  try {
    // ---- 2. Guardrail: the session role must be powerless --------------------
    const sup = await scalar(
      client,
      "SELECT rolsuper::text  FROM pg_roles WHERE rolname='semantius_authenticator'",
    );
    const byp = await scalar(
      client,
      "SELECT rolbypassrls::text FROM pg_roles WHERE rolname='semantius_authenticator'",
    );
    if (sup === null) {
      console.log("FAIL: semantius_authenticator role not found");
      return 1;
    }
    if (sup !== "false" || byp !== "false") {
      console.log(
        `FAIL: session role is privileged — rolsuper=${sup} rolbypassrls=${byp} (must both be false)`,
      );
      return 1;
    }
    console.log(
      `guardrail OK: rolsuper=${sup}  rolbypassrls=${byp}  (powerless, as required)`,
    );

    const claims = await claimsFor(sub);

    // ---- 3. First-login provisioning via the session path --------------------
    // get_userinfo() is SECURITY DEFINER (owned by the BYPASSRLS migration role),
    // so it works even though semantius_authenticator has no write grant. On a
    // FRESH database the first provisioned user also becomes Administrator
    // (auto_assign_user_role trigger) — expected, not a bug.
    try {
      await inSession(client, claims, async () => {
        await client.queryArray("SELECT public.get_userinfo()");
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (notDeployed(msg)) {
        console.log(`SKIP: _core not deployed (${msg})`);
        return 2;
      }
      throw e;
    }
    console.log(
      `provisioned/refreshed user sub="${sub}" via get_userinfo() (session path)`,
    );

    // ---- 4. Positive RLS path -----------------------------------------------
    const out = await inSession(client, claims, async () => {
      const uid = await scalar(client, "SELECT rbac.uid()");
      // Triggers RLS -> ensure_context_initialized() (needs the user row from #3).
      const visible = await scalar(client, "SELECT count(*)::text FROM users");
      return { uid, visible };
    });

    if (out.uid !== sub) {
      console.log(`FAIL: rbac.uid()="${out.uid}", expected "${sub}"`);
      return 1;
    }
    console.log(
      `OK  rbac.uid()="${out.uid}"  users visible under RLS=${out.visible}`,
    );
    console.log(
      "\nSESSION PATH OK: SCRAM connect -> SET LOCAL ROLE authenticated -> injected claims -> RLS-correct result.",
    );
    return 0;
  } finally {
    await client.end();
  }
}

if (import.meta.main) Deno.exit(await main());
