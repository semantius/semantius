import Link from "next/link";
import { redirect } from "next/navigation";
import { getSessionContext } from "@/lib/auth/context";
import { getAccessToken, tokenExpiresWithin } from "@/lib/auth/tokens";
import { getAdapter, withSession } from "@/lib/db/session";
import {
  getUserInfo,
  listAuditRecords,
  type AuditRecord,
  type UserInfo,
} from "@/lib/dal/users";

export const runtime = "nodejs";
export const dynamic = "force-dynamic"; // always render against the live session

/**
 * Audit-log viewer — the read-deny RLS demo. `audit_record_logs` SELECT is gated on
 * the `admin` permission, so an Administrator sees rows and a plain `User` sees an
 * empty set (no error). Same code, same query, opposite result — driven entirely by
 * the DB's RLS for the request's identity.
 */
export default async function AuditPage() {
  const token = await getAccessToken();
  if (!token) redirect("/api/auth/login?returnTo=/audit");

  // RSC can't write cookies during render; bounce through refresh if expiring.
  if (tokenExpiresWithin(token, 60)) redirect("/api/auth/refresh?returnTo=/audit");

  const ctx = await getSessionContext();
  if (!ctx) redirect("/api/auth/login?returnTo=/audit");

  const mode = getAdapter().mode;

  // One request-scoped read transaction: who am I + the audit rows RLS lets me see.
  let info: UserInfo | null = null;
  let records: AuditRecord[] = [];
  let readError: string | null = null;
  try {
    ({ info, records } = await withSession(ctx, async () => ({
      info: await getUserInfo(),
      records: await listAuditRecords(50),
    })));
  } catch (err) {
    readError = err instanceof Error ? err.message : String(err);
  }

  return (
    <>
      <p>
        <Link href="/">← Home</Link> · <Link href="/users">Users</Link>
      </p>
      <h1>Audit log</h1>
      <p className="muted">
        Read under RLS via <span className="badge">DB_AUTH_MODE = {mode}</span>.{" "}
        <code>audit_record_logs</code> requires the <code>admin</code> permission to
        SELECT — a non-admin gets zero rows, not an error.
      </p>

      {info && (
        <p className="muted">
          You are <code>{info.email ?? info.externalId}</code> with role{" "}
          <span className="badge">{info.roles.join(", ") || "(none)"}</span> —{" "}
          {info.isAdmin
            ? "you have admin, so the audit rows below are visible."
            : "you do NOT have admin, so RLS returns nothing below."}
        </p>
      )}

      {readError ? (
        <div className="card">
          <p className="result-err">Could not read the audit log: {readError}</p>
        </div>
      ) : records.length === 0 ? (
        <div className="card">
          <p className={info?.isAdmin ? "muted" : "result-err"}>
            {info?.isAdmin
              ? "No audit activity recorded yet."
              : "Access denied by RLS: 0 rows. Reading the audit log needs the admin " +
                "permission (the Administrator role) — your role does not have it, so " +
                "the database returns an empty set (no error). Sign in as an admin to see entries."}
          </p>
        </div>
      ) : (
        <>
          <table>
            <thead>
              <tr>
                <th>id</th>
                <th>when</th>
                <th>op</th>
                <th>table</th>
                <th>record pk</th>
                <th>by user_id</th>
              </tr>
            </thead>
            <tbody>
              {records.map((r) => (
                <tr key={r.id}>
                  <td>{r.id}</td>
                  <td className="muted">{new Date(r.ts).toISOString()}</td>
                  <td>
                    <code>{r.op}</code>
                  </td>
                  <td>{r.tableName}</td>
                  <td>
                    <code>{r.recordPk || "—"}</code>
                  </td>
                  <td className="muted">{r.userId || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="muted">{records.length} most-recent audit row(s) visible under RLS.</p>
        </>
      )}
    </>
  );
}
