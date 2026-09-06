import { useEffect, useState, type FormEvent } from "react";
import { Link } from "@tanstack/react-router";
import { useAuth } from "../auth/AuthContext";
import { ApiError, useApi } from "../api/client";
import type { MeResponse, UserDto, UserInfo, UsersResponse, WriteResponse } from "../types";

/** Users: provision (GET /me, the write path) + RLS read (GET /users) + the
 * user:manage write demo (PUT /me/display-name). */
export function Users() {
  const { status, claims } = useAuth();
  const api = useApi();

  const [rows, setRows] = useState<UserDto[]>([]);
  const [info, setInfo] = useState<UserInfo | null>(null);
  const [mode, setMode] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [name, setName] = useState("");
  const [writing, setWriting] = useState(false);
  const [writeMsg, setWriteMsg] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    // The route's beforeLoad guard rules out 'unauthenticated'; while 'loading'
    // (a token rehydrating/refreshing) we just wait — the page shows "Loading…".
    if (status !== "authenticated") return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setLoadError(null);
      try {
        const meRes = await api<MeResponse>("/me"); // provision (write path) + who am I
        const usersRes = await api<UsersResponse>("/users"); // RLS-enforced read
        if (cancelled) return;
        setMode(usersRes.mode);
        setRows(usersRes.users);
        setInfo(meRes.info);
        setName(meRes.me?.displayName ?? "");
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

  async function submitWrite(e: FormEvent) {
    e.preventDefault();
    setWriting(true);
    setWriteMsg(null);
    try {
      const res = await api<WriteResponse>("/me/display-name", {
        method: "PUT",
        body: JSON.stringify({ displayName: name }),
      });
      setWriteMsg({ ok: res.ok, text: res.message });
      if (res.ok) {
        const usersRes = await api<UsersResponse>("/users"); // re-read to show the new name
        setRows(usersRes.users);
      }
    } catch (err) {
      setWriteMsg({ ok: false, text: err instanceof ApiError ? err.message : String(err) });
    } finally {
      setWriting(false);
    }
  }

  return (
    <>
      <h1>Users</h1>
      <p className="muted">
        Read under RLS
        {mode ? (
          <>
            {" "}
            via <span className="badge">DB_AUTH_MODE = {mode}</span>
          </>
        ) : null}
        . Signed in as <code>{claims?.email ?? claims?.sub}</code>.
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
                "Admin is granted to the FIRST account to log in on a fresh DB, NOT by email."}{" "}
            <Link to="/audit">View the audit log →</Link>
          </p>
        </div>
      )}

      {loading && <p className="muted">Loading…</p>}

      {loadError && (
        <div className="card">
          <p className="err">Could not load users: {loadError}</p>
        </div>
      )}

      {!loading && !loadError && (
        <>
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
                  <td className="muted">{u.lastSeen ? new Date(u.lastSeen).toISOString() : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="muted">
            {rows.length} user(s) visible to <code>{claims?.sub}</code> under RLS.
          </p>
        </>
      )}

      <div className="card">
        <h2 className="card-title">Write demo</h2>
        <p className="muted">
          Updating a user requires the <code>user:manage</code> permission
          (Administrator). On a fresh per-developer DB the first user to log in is
          Administrator, so this works for them; a non-admin is correctly RLS-blocked.
        </p>
        <form onSubmit={submitWrite} className="row">
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="New display name"
            maxLength={200}
          />
          <button type="submit" disabled={writing}>
            {writing ? "Saving…" : "Update my display name"}
          </button>
        </form>
        {writeMsg && <p className={writeMsg.ok ? "ok" : "err"}>{writeMsg.text}</p>}
      </div>
    </>
  );
}
