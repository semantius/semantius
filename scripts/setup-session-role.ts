#!/usr/bin/env -S deno run --allow-read --allow-env --allow-net
/**
 * setup-session-role.ts  -  give `semantius_authenticator` a LOGIN + password on
 * a MANAGED platform (Supabase / Neon), over the privileged OWNER connection.
 *
 * The core migrations (apps/_core/migrations/0011) create the role NOLOGIN
 * NOSUPERUSER NOINHERIT and GRANT it `authenticated` on every deployment. On
 * local pgdocker, init/11-session-role.sh sets the LOGIN + password. On managed
 * platforms there is no such init hook, so run THIS once, as the owner, to flip
 * the role to LOGIN and set its password. The app then connects as
 * `semantius_authenticator` (DB_AUTH_MODE=session) — NEVER as the owner (the
 * owner bypasses RLS).
 *
 * Connection (owner) — same precedence as the Semantius CLI:
 *   1. --database-url <url>
 *   2. $DATABASE_URL
 *   3. .env.<env>  (default env "local"; override with --env <name>)
 * Password:
 *   $SEMANTIUS_AUTHENTICATOR_PASSWORD  (or --password <pw>) — REQUIRED, no default.
 *
 * The password is applied via server-side format(%L) quoting (never string-
 * concatenated client-side), so specials/quotes are handled safely. Idempotent.
 *
 *   SEMANTIUS_AUTHENTICATOR_PASSWORD=... deno task setup-session-role --env supabase
 *   deno task setup-session-role --database-url 'postgresql://owner:pw@host:6543/db?sslmode=require' --password '...'
 */
import { load } from "https://deno.land/std@0.208.0/dotenv/mod.ts";
import { Client } from "https://deno.land/x/postgres@v0.17.0/mod.ts";

function flag(name: string): string | undefined {
  const i = Deno.args.indexOf(`--${name}`);
  return i >= 0 ? Deno.args[i + 1] : undefined;
}

async function ownerUrl(): Promise<string> {
  const cli = flag("database-url");
  if (cli) return cli;
  const fromEnv = Deno.env.get("DATABASE_URL");
  if (fromEnv) return fromEnv;
  const env = flag("env") ?? "local";
  const vars = await load({ envPath: `.env.${env}` });
  const url = vars.DATABASE_URL;
  if (!url) {
    console.error(
      `DATABASE_URL not found in .env.${env}, $DATABASE_URL, or --database-url`,
    );
    Deno.exit(1);
  }
  return url;
}

async function main(): Promise<number> {
  const password = Deno.env.get("SEMANTIUS_AUTHENTICATOR_PASSWORD") ??
    flag("password");
  if (!password) {
    console.error(
      "Set SEMANTIUS_AUTHENTICATOR_PASSWORD (env) or pass --password <pw>. " +
        "Use a real, per-environment secret — never a shared/static value.",
    );
    return 1;
  }

  const url = await ownerUrl();
  const client = new Client(url);
  await client.connect();
  try {
    // Sanity: warn loudly if the OWNER string is NOT a superuser/owner — this
    // task is meant to run as the privileged role, not as semantius_authenticator.
    const who = (await client.queryArray<[string, boolean]>(
      "SELECT current_user, (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)",
    )).rows[0];
    console.log(`connected as "${who[0]}" (rolsuper=${who[1]})`);

    // Ensure the role exists with the right floor + membership (idempotent).
    // Created by 0011 on a migrated DB; this covers running before migrate too.
    await client.queryArray(`
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
          CREATE ROLE authenticated NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
          CREATE ROLE semantius_authenticator LOGIN NOSUPERUSER NOINHERIT;
        ELSE
          ALTER ROLE semantius_authenticator LOGIN NOSUPERUSER NOINHERIT;
        END IF;
        GRANT authenticated TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
      END
      $$;
    `);

    // Set the password via server-side %L quoting (safe; never concatenated here).
    const built = (await client.queryArray<[string]>({
      text:
        "SELECT format('ALTER ROLE semantius_authenticator PASSWORD %L', $1::text)",
      args: [password],
    })).rows[0][0];
    await client.queryArray(built);

    // Confirm the floor.
    const r = (await client.queryArray<[boolean, boolean, boolean]>(
      "SELECT rolcanlogin, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'semantius_authenticator'",
    )).rows[0];
    console.log(
      `semantius_authenticator: LOGIN=${r[0]} rolsuper=${r[1]} rolbypassrls=${
        r[2]
      }`,
    );
    if (!r[0] || r[1] || r[2]) {
      console.error(
        "Unexpected role state — must be LOGIN, NOT superuser, NOT bypassrls.",
      );
      return 1;
    }
    console.log(
      "\nDone. Connect the app in session mode as:\n" +
        "  postgresql://semantius_authenticator:<pw>@<host>:<port>/<db>?sslmode=require\n" +
        "Never use the owner/superuser connection string for app traffic (it bypasses RLS).",
    );
    return 0;
  } finally {
    await client.end();
  }
}

if (import.meta.main) Deno.exit(await main());
