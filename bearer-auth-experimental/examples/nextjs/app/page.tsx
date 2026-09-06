import Link from "next/link";
import { getSessionContext } from "@/lib/auth/context";
import { getAdapter } from "@/lib/db/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export default async function Home() {
  const mode = getAdapter().mode;
  const ctx = await getSessionContext();

  return (
    <>
      <h1>Semantius · Next.js sample</h1>
      <p className="muted">
        OAuth (authorization-code + PKCE, no secret) → request-scoped transaction →
        Drizzle under RLS. The same code runs against PostgreSQL&nbsp;18
        OAUTHBEARER, Neon, and Supabase.
      </p>

      <div className="card">
        <p>
          Adapter: <span className="badge">DB_AUTH_MODE = {mode}</span>{" "}
          {mode === "bearer" ? (
            <span className="muted">
              — the end-user&apos;s token authenticates the DB connection; the
              database verifies it (pg_oidc_validator, RS256).
            </span>
          ) : (
            <span className="muted">
              — the app connects as <code>semantius_authenticator</code> and
              injects app-verified claims (the app is the trust boundary).
            </span>
          )}
        </p>

        {ctx ? (
          <p>
            Signed in as <code>{ctx.claims.email ?? ctx.claims.sub}</code>{" "}
            (<code>sub={ctx.claims.sub}</code>). →{" "}
            <Link href="/users">View users</Link>
          </p>
        ) : (
          <p>
            Not signed in. <Link href="/api/auth/login?returnTo=/users">Log in</Link>{" "}
            to continue.
          </p>
        )}
      </div>
    </>
  );
}
