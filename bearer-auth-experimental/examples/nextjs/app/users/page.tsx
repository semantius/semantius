import Link from "next/link";
import { redirect } from "next/navigation";
import { getSessionContext } from "@/lib/auth/context";
import { getAccessToken, tokenExpiresWithin } from "@/lib/auth/tokens";
import { getAdapter, withSession } from "@/lib/db/session";
import { getUserInfo, listUsers, type UserInfo, type UserRow } from "@/lib/dal/users";
import { UpdateNameForm } from "./update-name-form";
import { logoutAction } from "./actions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic"; // always render against the live session

export default async function UsersPage() {
  const token = await getAccessToken();
  if (!token) redirect("/api/auth/login?returnTo=/users");

  // RSC can't write cookies during render, so if the token is expiring we bounce
  // through the refresh route (which writes the new cookies) and back here.
  if (tokenExpiresWithin(token, 60)) redirect("/api/auth/refresh?returnTo=/users");

  const ctx = await getSessionContext();
  if (!ctx) redirect("/api/auth/login?returnTo=/users");

  const mode = getAdapter().mode;

  // ONE request-scoped read transaction for everything this page renders (plan §2:
  // a single session/render, not one per component, to avoid the fan-out cliff).
  // getUserInfo() both provisions AND returns the caller's roles/permissions, so
  // the UI can show your real role instead of guessing from your email.
  let rows: UserRow[] = [];
  let info: UserInfo | null = null;
  let readError: string | null = null;
  try {
    ({ rows, info } = await withSession(ctx, async () => ({
      rows: await listUsers(),
      info: await getUserInfo(),
    })));
  } catch (err) {
    readError = err instanceof Error ? err.message : String(err);
  }

  return (
    <>
      <p>
        <Link href="/">← Home</Link>
      </p>
      <h1>Users</h1>
      <p className="muted">
        Read under RLS via <span className="badge">DB_AUTH_MODE = {mode}</span>.
        Signed in as <code>{ctx.claims.email ?? ctx.claims.sub}</code>.
      </p>

      {info && (
        <div className="card">
          <p style={{ margin: 0 }}>
            You are <code>{info.email ?? info.externalId}</code> (
            <code>sub={info.externalId}</code>) with role{" "}
            <span className="badge">{info.roles.join(", ") || "(none)"}</span>.
          </p>
          <p className="muted" style={{ marginBottom: 0 }}>
            {info.canManageUsers
              ? "You hold user:manage (Administrator) → the write demo below will succeed."
              : "You do NOT hold user:manage → the write demo below is correctly RLS-blocked. " +
                "Admin is granted to the FIRST account to log in on a fresh DB, NOT by email — so " +
                "an account called admin@test.com is not necessarily the Administrator."}{" "}
            <Link href="/audit">View the audit log →</Link>
          </p>
        </div>
      )}

      {readError ? (
        <div className="card">
          <p className="result-err">Could not read users: {readError}</p>
          <p className="muted">
            If this says “User not found”, your row hasn&apos;t been provisioned
            yet — <Link href="/api/auth/login?returnTo=/users">log in again</Link>{" "}
            (login calls <code>public.get_userinfo()</code>), or run the write
            action below (it provisions defensively).
          </p>
        </div>
      ) : (
        <table>
          <thead>
            <tr>
              <th>id</th>
              <th>email</th>
              <th>display name</th>
              <th>external_id (sub)</th>
              <th>last seen</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((u) => (
              <tr key={u.id}>
                <td>{u.id}</td>
                <td>{u.email}</td>
                <td>{u.displayName}</td>
                <td>
                  <code>{u.externalId}</code>
                </td>
                <td className="muted">
                  {u.lastSeen ? new Date(u.lastSeen).toISOString() : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {!readError && (
        <p className="muted">
          {rows.length} user(s) visible to <code>{ctx.claims.sub}</code> under RLS.
        </p>
      )}

      <div className="card">
        <h2 style={{ fontSize: "1.1rem", marginTop: 0 }}>Write demo</h2>
        <p className="muted">
          Updating a user requires the <code>user:manage</code> permission
          (Administrator). On a fresh per-developer DB the first user to log in is
          Administrator, so this works for them; a non-admin is correctly blocked
          by RLS.
        </p>
        <UpdateNameForm current={info?.displayName ?? ""} />
      </div>

      <form action={logoutAction}>
        <button type="submit" className="secondary">
          Sign out
        </button>
      </form>
    </>
  );
}
