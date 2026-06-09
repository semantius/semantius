// =============================================================================
// context.ts — resolve the request's SessionContext (token + claims).
//
// SESSION mode: verify the token here (jose, fail-closed). The app is the SOLE
//   trust boundary — only verified claims are ever produced.
// BEARER mode: the DATABASE verifies the token (system_user is authoritative), so
//   we only need the raw token; claims are decoded-but-unverified for display.
//
// getSessionContext() is memoized with React cache() so the cookie read + verify
// happen ONCE per render, shared across all server components (plan §2: avoid the
// per-component fan-out).
// =============================================================================

import { cache } from "react";
import { getAdapter } from "@/lib/db/session";
import { unsafeDecodeForBearer, verifyAccessToken } from "@/lib/db/verify";
import type { SessionContext } from "@/lib/db/adapter";
import { getAccessToken } from "./tokens";

/**
 * Build a SessionContext from a raw token. Throws in session mode if verification
 * fails (fail-closed) — callers treat that as "no session".
 */
export async function resolveSessionContext(token: string): Promise<SessionContext> {
  if (getAdapter().mode === "session") {
    const claims = await verifyAccessToken(token);
    return { token, claims };
  }
  // bearer: DB is the trust boundary; decode only for display / "who am I".
  return { token, claims: unsafeDecodeForBearer(token) };
}

/** The current request's SessionContext, or null if not signed in / unverifiable.
 * Memoized per render. */
export const getSessionContext = cache(async (): Promise<SessionContext | null> => {
  const token = await getAccessToken();
  if (!token) return null;
  try {
    return await resolveSessionContext(token);
  } catch {
    return null; // fail-closed: a bad/expired token => no session
  }
});
