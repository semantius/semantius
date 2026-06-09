// =============================================================================
// session middleware — the resource-server trust boundary + request-scoped tx.
//
// This is the Hono analogue of the Next sample's lib/auth/context.ts +
// lib/db/session.ts withSession() wrapper, but a pure RESOURCE SERVER: the token
// arrives in the `Authorization: Bearer` header (not a cookie), and every data
// request runs inside ONE transaction selected by DB_AUTH_MODE.
//
//   session mode: the APP verifies the JWT here (jose: RS256 pinned + iss + aud,
//     fail-closed) — it is the SOLE trust boundary, so only verified claims are
//     ever injected into request.jwt.claims downstream.
//   bearer mode: the DATABASE is the trust boundary (PG18 pg_oidc_validator
//     validates the signature, system_user pins identity). We only need the raw
//     token; claims are decoded-but-unverified for display.
// =============================================================================

import { createMiddleware } from "hono/factory";
import { decodeJwt } from "jose";
import { getAdapter, withSession } from "../../lib/db/session";
import { unsafeDecodeForBearer, verifyAccessToken } from "../../lib/db/verify";
import type { DbAuthMode, SessionContext } from "../../lib/db/adapter";
import type { VerifiedClaims } from "../../lib/db/verify";

export interface AppEnv {
  Variables: {
    claims: VerifiedClaims;
    mode: DbAuthMode;
  };
}

/**
 * Resolve the request's SessionContext from a raw bearer token. Mirrors the Next
 * sample's resolveSessionContext: verify (and fail closed) in session mode; decode
 * only in bearer mode. Throws in session mode if verification fails.
 */
async function resolveSessionContext(token: string): Promise<SessionContext> {
  if (getAdapter().mode === "session") {
    return { token, claims: await verifyAccessToken(token) };
  }
  return { token, claims: unsafeDecodeForBearer(token) };
}

export const sessionMiddleware = createMiddleware<AppEnv>(async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "";
  if (!token) {
    return c.json(
      { error: "missing_token", message: "Authorization: Bearer <token> is required." },
      401,
    );
  }

  // Cheap exp PRE-check (decode only, no signature) so an expired token yields a
  // uniform 401 in BOTH modes → the SPA's 401→refresh→retry path works the same
  // way regardless of DB_AUTH_MODE. Real verification still happens below
  // (session: jose; bearer: the DB during the OAUTHBEARER handshake).
  let expSeconds: number | undefined;
  try {
    expSeconds = decodeJwt(token).exp;
  } catch {
    return c.json({ error: "malformed_token", message: "Bearer token is not a JWT." }, 401);
  }
  if (expSeconds !== undefined && expSeconds * 1000 <= Date.now()) {
    return c.json({ error: "expired_token", message: "Access token has expired." }, 401);
  }

  let ctx: SessionContext;
  try {
    ctx = await resolveSessionContext(token);
  } catch (err) {
    // session mode: jose verification failed (bad signature / iss / aud / exp /
    // JWKS unreachable). Fail closed — never inject claims from an unverified token.
    return c.json(
      {
        error: "invalid_token",
        message: err instanceof Error ? err.message : "token verification failed",
      },
      401,
    );
  }

  c.set("claims", ctx.claims);
  c.set("mode", getAdapter().mode);

  // ONE request-scoped transaction. The adapter handles BEGIN, (session) SET LOCAL
  // ROLE authenticated + claim injection, COMMIT/ROLLBACK, and release. The route
  // handler runs inside it via next(); the DAL reads the tx handle through getDb()
  // (the db layer's own AsyncLocalStorage).
  await withSession(ctx, async () => {
    await next();
  });
});
