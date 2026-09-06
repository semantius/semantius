// =============================================================================
// Local API DTOs — hand-written so the SPA stays 100% free of any DB / Drizzle /
// node-postgres dependency (plan Open Question #7: local minimal types, not
// imported from the backend). These mirror the Hono API's JSON shapes.
//
// NOTE: `lastSeen` is a string here (not Date) — Drizzle returns a Date which is
// JSON-serialized to an ISO string over the wire.
// =============================================================================

export interface UserDto {
  id: number;
  externalId: string;
  email: string;
  displayName: string;
  lastSeen: string | null;
}

/** "Who am I + what can I do" — mirrors the API's UserInfo (from get_userinfo). */
export interface UserInfo {
  userId: number;
  externalId: string;
  email: string | null;
  displayName: string;
  roles: string[];
  permissions: string[];
  canManageUsers: boolean;
  isAdmin: boolean;
}

export interface MeResponse {
  me: UserDto | null;
  info: UserInfo;
  mode: string;
  sub: string;
}

export interface UsersResponse {
  users: UserDto[];
  mode: string;
}

export interface WriteResponse {
  ok: boolean;
  message: string;
}

export interface AuditRecord {
  id: number;
  ts: string;
  op: string;
  tableName: string;
  recordPk: string;
  userId: number;
}

export interface AuditResponse {
  records: AuditRecord[];
  info: UserInfo;
  mode: string;
}
