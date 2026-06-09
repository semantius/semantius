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

export interface MeResponse {
  me: UserDto | null;
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
