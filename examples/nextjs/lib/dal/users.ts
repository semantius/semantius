// =============================================================================
// users DAL — data access over the ambient request-scoped session (getDb()).
// Every function here MUST be called inside a withSession()/read() scope.
// =============================================================================

import { eq, sql } from "drizzle-orm";
import { getDb } from "../db/session";
import { users } from "../db/schema";

export interface UserRow {
  id: number;
  externalId: string;
  email: string;
  displayName: string;
  lastSeen: Date | null;
}

/**
 * First-login provisioning. public.get_userinfo() (SECURITY DEFINER) INSERTs the
 * caller's users row if missing; the AFTER INSERT trigger auto-assigns the `User`
 * role (user:read + public:read) — and `Administrator` to the FIRST user on a
 * fresh DB. Idempotent on later calls. Must run before the first RLS read, or
 * rbac.ensure_context_initialized() raises "User not found".
 */
export async function provisionCurrentUser(): Promise<void> {
  await getDb().execute(sql`select public.get_userinfo()`);
}

/** All users visible under RLS. Any provisioned user has `user:read`, so this
 * returns the full table; it demonstrates RLS gating, not row-level filtering. */
export async function listUsers(): Promise<UserRow[]> {
  return getDb()
    .select({
      id: users.id,
      externalId: users.externalId,
      email: users.email,
      displayName: users.displayName,
      lastSeen: users.lastSeen,
    })
    .from(users)
    .orderBy(users.id);
}

/** The current user's row, looked up by the token's `sub` (= users.external_id). */
export async function getUserByExternalId(externalId: string): Promise<UserRow | null> {
  const rows = await getDb()
    .select({
      id: users.id,
      externalId: users.externalId,
      email: users.email,
      displayName: users.displayName,
      lastSeen: users.lastSeen,
    })
    .from(users)
    .where(eq(users.externalId, externalId))
    .limit(1);
  return rows[0] ?? null;
}

/**
 * Update a user's display name. Writing to `users` requires the `user:manage`
 * permission (the Administrator role) per RLS users_update_policy. A plain `User`
 * is filtered out by the policy's USING clause → 0 rows affected (no error). The
 * returned count lets the caller distinguish "done" from "RLS-blocked".
 */
export async function updateDisplayName(userId: number, displayName: string): Promise<number> {
  const updated = await getDb()
    .update(users)
    .set({ displayName })
    .where(eq(users.id, userId))
    .returning({ id: users.id });
  return updated.length;
}

// -----------------------------------------------------------------------------
// "Who am I + what can I do", straight from public.get_userinfo().
// -----------------------------------------------------------------------------

export interface UserInfo {
  userId: number;
  externalId: string;
  email: string | null;
  displayName: string;
  roles: string[];
  permissions: string[];
  /** has the `user:manage` permission → may write to `users` (the write demo). */
  canManageUsers: boolean;
  /** has the `admin` permission → may read the audit log. */
  isAdmin: boolean;
}

/**
 * One adapter-agnostic read of a single jsonb column: session mode (node-postgres)
 * returns rows keyed by the column alias, bearer mode (pg-proxy) returns positional
 * arrays — a single aliased `j` column reads correctly in both. jsonb is already
 * parsed to a JS value by both adapters (node-postgres / pg-types).
 */
async function readJson<T>(query: ReturnType<typeof sql>): Promise<T | null> {
  // The two adapters return db.execute() in DIFFERENT shapes:
  //   session (node-postgres): a QueryResult — { rows: [{ j: <value> }] }  (keyed)
  //   bearer  (drizzle pg-proxy): the rows array directly — [[<value>]]     (positional)
  // Normalize both, then pull the single aliased `j` column out of the first row.
  const res = (await getDb().execute(query)) as unknown;
  const rows = (Array.isArray(res) ? res : (res as { rows?: unknown[] })?.rows ?? []) as Array<
    Record<string, unknown> | unknown[]
  >;
  const row = rows[0];
  if (row == null) return null;
  return (Array.isArray(row) ? row[0] : (row as Record<string, unknown>).j) as T;
}

/**
 * Provision (idempotent) AND return the caller's identity, roles, and permissions
 * from public.get_userinfo(). It is SECURITY DEFINER, so it returns the user's OWN
 * roles/permissions even though RLS hides `user_roles`/`roles` from a non-admin —
 * which is exactly why the UI must source "am I admin?" from here, not from a
 * direct read of those tables. This is the authoritative answer the demo needs.
 */
export async function getUserInfo(): Promise<UserInfo> {
  const info = await readJson<{
    user_id: number;
    external_id: string;
    email: string | null;
    display_name: string | null;
    roles: Array<{ role_name: string }> | null;
    permissions: string[] | null;
  }>(sql`select public.get_userinfo() as j`);
  if (!info) throw new Error("get_userinfo() returned no row");
  const permissions = info.permissions ?? [];
  return {
    userId: info.user_id,
    externalId: info.external_id,
    email: info.email,
    displayName: info.display_name ?? "",
    roles: (info.roles ?? []).map((r) => r.role_name),
    permissions,
    canManageUsers: permissions.includes("user:manage"),
    isAdmin: permissions.includes("admin"),
  };
}

// -----------------------------------------------------------------------------
// Audit log — an admin-only READ (the read-deny RLS demo).
// -----------------------------------------------------------------------------

export interface AuditRecord {
  id: number;
  ts: string; // ISO timestamp (jsonb serializes timestamptz to a string)
  op: string; // INSERT | UPDATE | DELETE | TRUNCATE
  tableName: string;
  recordPk: string;
  userId: number;
}

/**
 * Recent DML audit entries. `audit_record_logs` SELECT is RLS-gated on the `admin`
 * permission (0150_audit_log.sql), so an admin sees rows and a non-admin sees ZERO
 * rows — no error, just an empty set. That asymmetry is the demo. The table isn't
 * in the vendored Drizzle schema, so we query it raw and aggregate to one jsonb
 * column (portable across both adapters via readJson()).
 */
export async function listAuditRecords(limit = 50): Promise<AuditRecord[]> {
  const arr = await readJson<
    Array<{
      id: number;
      ts: string;
      op: string;
      table_name: string;
      record_pk: string;
      user_id: number;
    }>
  >(sql`
    select coalesce(jsonb_agg(x order by x.ts desc), '[]'::jsonb) as j
    from (
      select id, ts, op, table_name, record_pk, user_id
      from audit_record_logs
      order by ts desc
      limit ${limit}
    ) x
  `);
  return (arr ?? []).map((r) => ({
    id: r.id,
    ts: r.ts,
    op: r.op,
    tableName: r.table_name,
    recordPk: r.record_pk,
    userId: r.user_id,
  }));
}
