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
