// =============================================================================
// Data routes — all run INSIDE the request-scoped transaction opened by
// sessionMiddleware (applied below), so the DAL's getDb() resolves the tx handle
// and every query is RLS-enforced for the request's identity.
//
//   GET /me               first-call provisioning (write path) + current user
//   GET /users            RLS-enforced list (any provisioned user has user:read)
//   PUT /me/display-name  the user:manage write demo (admin / first user only)
// =============================================================================

import { Hono } from "hono";
import { sessionMiddleware, type AppEnv } from "../middleware/session";
import {
  getUserByExternalId,
  getUserInfo,
  listAuditRecords,
  listUsers,
  provisionCurrentUser,
  updateDisplayName,
} from "../../lib/dal/users";

export const data = new Hono<AppEnv>();

// Auth + request-scoped transaction for EVERY data route. CORS (incl. the OPTIONS
// preflight) is handled earlier and globally in server.ts, so the credential-less
// preflight never reaches this.
data.use("*", sessionMiddleware);

/**
 * First-login provisioning. public.get_userinfo() (SECURITY DEFINER) INSERTs the
 * caller's users row if missing, firing the AFTER INSERT trigger that auto-assigns
 * the `User` role (and `Administrator` to the FIRST user on a fresh DB). Idempotent.
 * The SPA calls this once on load before reading /users (which needs the row to
 * exist, or rbac raises "User not found").
 */
data.get("/me", async (c) => {
  const info = await getUserInfo(); // provisions (idempotent) + returns roles/permissions
  const me = await getUserByExternalId(c.get("claims").sub);
  return c.json({ me, info, mode: c.get("mode"), sub: c.get("claims").sub });
});

/** All users visible under RLS. Demonstrates RLS gating (user:read), not row
 * filtering — any provisioned user sees the whole table. */
data.get("/users", async (c) => {
  const users = await listUsers();
  return c.json({ users, mode: c.get("mode") });
});

/**
 * Audit log — the read-deny RLS demo. `audit_record_logs` SELECT requires the
 * `admin` permission (Administrator), so an admin sees rows and a plain `User`
 * gets ZERO rows (no error). `info` lets the SPA word the empty state correctly.
 */
data.get("/audit", async (c) => {
  const info = await getUserInfo();
  const records = await listAuditRecords(50);
  return c.json({ records, info, mode: c.get("mode") });
});

/**
 * Write demo: update the signed-in user's display name. Writing to `users`
 * requires the `user:manage` permission (the Administrator role); a plain `User`
 * is RLS-filtered → 0 rows affected (no error). On a fresh per-developer DB the
 * FIRST user to log in is Administrator, so this succeeds for them.
 */
data.put("/me/display-name", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { displayName?: unknown };
  const displayName = String(body.displayName ?? "").trim();
  if (!displayName) {
    return c.json({ ok: false, message: "Display name is required." }, 400);
  }
  if (displayName.length > 200) {
    return c.json({ ok: false, message: "Display name is too long (max 200 chars)." }, 400);
  }

  await provisionCurrentUser(); // idempotent; ensures the row exists
  const me = await getUserByExternalId(c.get("claims").sub);
  if (!me) {
    return c.json({ ok: false, message: "Your user row was not found." }, 404);
  }

  const updated = await updateDisplayName(me.id, displayName);
  if (updated === 0) {
    return c.json({
      ok: false,
      message:
        "Blocked by RLS: writing to users needs the user:manage permission (the " +
        "Administrator role). On a fresh per-developer DB the FIRST user to log in " +
        "becomes Administrator; a non-admin is correctly denied.",
    });
  }
  return c.json({ ok: true, message: `Updated your display name to "${displayName}".` });
});
