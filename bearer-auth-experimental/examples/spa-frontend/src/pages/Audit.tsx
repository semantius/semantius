import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useAuth } from "../auth/AuthContext";
import { ApiError, useApi } from "../api/client";
import type { AuditRecord, AuditResponse, UserInfo } from "../types";

/** Audit log viewer — the read-deny RLS demo. `audit_record_logs` requires the
 * `admin` permission to SELECT, so an Administrator sees rows and a plain `User`
 * gets an empty set (no error). Same request, opposite result, driven by RLS. */
export function Audit() {
  const { status } = useAuth();
  const api = useApi();

  const [records, setRecords] = useState<AuditRecord[]>([]);
  const [info, setInfo] = useState<UserInfo | null>(null);
  const [mode, setMode] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    if (status !== "authenticated") return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setLoadError(null);
      try {
        const res = await api<AuditResponse>("/audit");
        if (cancelled) return;
        setRecords(res.records);
        setInfo(res.info);
        setMode(res.mode);
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof ApiError ? err.message : String(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [status, api]);

  return (
    <>
      <h1>Audit log</h1>
      <p className="muted">
        Read under RLS
        {mode ? (
          <>
            {" "}
            via <span className="badge">DB_AUTH_MODE = {mode}</span>
          </>
        ) : null}
        . <code>audit_record_logs</code> requires the <code>admin</code> permission to
        SELECT — a non-admin gets zero rows, not an error.{" "}
        <Link to="/users">← Back to users</Link>
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

      {loading && <p className="muted">Loading…</p>}

      {loadError && (
        <div className="card">
          <p className="err">Could not load the audit log: {loadError}</p>
        </div>
      )}

      {!loading && !loadError && records.length === 0 && (
        <div className="card">
          <p className={info?.isAdmin ? "muted" : "err"}>
            {info?.isAdmin
              ? "No audit activity recorded yet."
              : "Access denied by RLS: 0 rows. Reading the audit log needs the admin " +
                "permission (the Administrator role) — your role does not have it, so the " +
                "database returns an empty set (no error). Sign in as an admin to see entries."}
          </p>
        </div>
      )}

      {!loading && !loadError && records.length > 0 && (
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
