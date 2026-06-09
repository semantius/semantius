// =============================================================================
// verify.ts — app-side JWT verification for SESSION mode (the MANDATORY trust
// boundary). Nothing in the DB verifies the signature in session mode, so this
// is the protection. Fail-closed: any failure throws and the caller MUST reject
// (no session) and NEVER inject claims.
// =============================================================================

import { createRemoteJWKSet, decodeJwt, jwtVerify, type JWTPayload } from "jose";
import { requireEnv } from "./env";

/** The exact verified payload we inject into request.jwt.claims (role pinned). */
export interface VerifiedClaims extends JWTPayload {
  sub: string;
  role: "authenticated";
  email?: string;
}

export class TokenVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TokenVerificationError";
  }
}

// createRemoteJWKSet caches keys in-process (refetches only on an unknown kid),
// so there is no per-request JWKS fetch. Memoized for the lifetime of the process.
let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;
function getJwks(): ReturnType<typeof createRemoteJWKSet> {
  if (jwks) return jwks;
  // OAUTH_JWKS_URI is REQUIRED in session mode. We do not guess a path or fall
  // back to a stale/empty keyset — fail-closed.
  jwks = createRemoteJWKSet(new URL(requireEnv("OAUTH_JWKS_URI")));
  return jwks;
}

/**
 * Verify an access token for SESSION mode.
 *
 * - RS256 PINNED (never trust the token's alg header — blocks alg-confusion).
 * - `issuer` and `audience` are MANDATORY: a same-issuer token minted for another
 *   client must be rejected, independent of the DB's optional aud check.
 * - On ANY failure (bad signature, expired, wrong iss/aud, JWKS unreachable) this
 *   throws. The caller treats that as "no session" and never injects claims.
 *
 * The returned object is the EXACT verified payload, with `role` pinned to
 * 'authenticated' server-side (never trusted from the token). Inject THIS object
 * into request.jwt.claims — never a separate decode or a client-merged object.
 */
export async function verifyAccessToken(token: string): Promise<VerifiedClaims> {
  const issuer = requireEnv("OAUTH_ISSUER");
  const audience = requireEnv("OAUTH_EXPECTED_AUD");

  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, getJwks(), {
      algorithms: ["RS256"],
      issuer,
      audience,
    }));
  } catch (err) {
    throw new TokenVerificationError(
      `JWT verification failed: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  if (typeof payload.sub !== "string" || payload.sub.length === 0) {
    throw new TokenVerificationError("token is missing the required `sub` claim");
  }

  return { ...payload, sub: payload.sub, role: "authenticated" };
}

/**
 * Decode a token WITHOUT verifying it — for bearer mode only, where the DATABASE
 * is the trust boundary (pg_oidc_validator validates the RS256 signature and
 * PostgreSQL pins identity via system_user). We use the decoded claims purely for
 * display / "who am I" lookups, NEVER as a trust decision. Do not use in session
 * mode.
 */
export function unsafeDecodeForBearer(token: string): VerifiedClaims {
  const p = decodeJwt(token);
  return { ...p, sub: typeof p.sub === "string" ? p.sub : "", role: "authenticated" };
}
