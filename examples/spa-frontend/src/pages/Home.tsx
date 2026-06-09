import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useAuth } from "../auth/AuthContext";

/** Home: sign-in status + a Log in button. Also probes the API's GET / (no auth)
 * to display which DB_AUTH_MODE the backend is running — the SPA itself is
 * mode-agnostic. */
export function Home() {
  const { status, claims, login, error } = useAuth();
  const [backendMode, setBackendMode] = useState<string | null>(null);
  const [backendError, setBackendError] = useState<string | null>(null);

  useEffect(() => {
    fetch(`${import.meta.env.VITE_API_BASE_URL}/`)
      .then((r) => r.json())
      .then((d: { mode?: unknown }) => setBackendMode(typeof d.mode === "string" ? d.mode : null))
      .catch(() => setBackendError("API not reachable — is the Hono backend running on :8788?"));
  }, []);

  return (
    <>
      <h1>OAuth → Hono API → Drizzle under RLS</h1>
      <p className="muted">
        A browser React SPA runs authorization-code + PKCE (no secret) and calls a
        standalone Hono API with a bearer token. The API enforces per-user access via
        PostgreSQL RLS/RBAC.
      </p>

      <div className="card">
        {backendMode && (
          <p>
            Backend <span className="badge">DB_AUTH_MODE = {backendMode}</span>
          </p>
        )}
        {backendError && <p className="err">{backendError}</p>}

        {status === "authenticated" ? (
          <p>
            Signed in as <code>{claims?.email ?? claims?.sub}</code>. →{" "}
            <Link to="/users">View users</Link>
          </p>
        ) : (
          <p>
            Not signed in.{" "}
            <button onClick={() => void login()}>Log in</button>
          </p>
        )}
        {error && <p className="err">Sign-in error: {error}</p>}
      </div>
    </>
  );
}
