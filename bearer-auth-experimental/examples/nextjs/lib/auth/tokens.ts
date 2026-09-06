// =============================================================================
// tokens.ts — httpOnly cookie storage for OAuth tokens and the short-lived login
// (PKCE) state. Tokens are NEVER exposed to client JS, logged, or put in URLs.
//
// Cookie attributes: httpOnly + Secure + SameSite=Lax + Path=/. Lax (not Strict)
// so the login-state cookie survives the top-level redirect back from the IdP.
// Secure is fine on http://localhost — modern browsers treat localhost as a
// secure context and still send Secure cookies there.
//
// cookies() is async in Next 15 and writable only from route handlers / server
// actions (not during RSC render).
// =============================================================================

import { cookies } from "next/headers";

const ACCESS_COOKIE = "sty_at";
const REFRESH_COOKIE = "sty_rt";
const LOGIN_STATE_COOKIE = "sty_login";

const baseCookie = {
  httpOnly: true,
  secure: true,
  sameSite: "lax",
  path: "/",
} as const;

export interface LoginState {
  state: string;
  nonce: string;
  codeVerifier: string;
  returnTo: string;
}

export async function setLoginState(s: LoginState): Promise<void> {
  const store = await cookies();
  store.set(LOGIN_STATE_COOKIE, JSON.stringify(s), { ...baseCookie, maxAge: 600 });
}

/** Read and CLEAR the login-state cookie (single use). */
export async function takeLoginState(): Promise<LoginState | null> {
  const store = await cookies();
  const c = store.get(LOGIN_STATE_COOKIE);
  if (!c) return null;
  store.delete(LOGIN_STATE_COOKIE);
  try {
    return JSON.parse(c.value) as LoginState;
  } catch {
    return null;
  }
}

export interface TokenSet {
  accessToken: string;
  refreshToken?: string;
  expiresIn?: number;
}

export async function setTokens(t: TokenSet): Promise<void> {
  const store = await cookies();
  store.set(ACCESS_COOKIE, t.accessToken, {
    ...baseCookie,
    maxAge: t.expiresIn ?? 3600,
  });
  if (t.refreshToken) {
    store.set(REFRESH_COOKIE, t.refreshToken, {
      ...baseCookie,
      maxAge: 60 * 60 * 24 * 14, // 14 days
    });
  }
}

export async function clearTokens(): Promise<void> {
  const store = await cookies();
  store.delete(ACCESS_COOKIE);
  store.delete(REFRESH_COOKIE);
}

export async function getAccessToken(): Promise<string | null> {
  return (await cookies()).get(ACCESS_COOKIE)?.value ?? null;
}

export async function getRefreshToken(): Promise<string | null> {
  return (await cookies()).get(REFRESH_COOKIE)?.value ?? null;
}

/**
 * True if the access token's `exp` is within `skewSeconds` of now (or can't be
 * read). This is a cheap proactive-refresh hint from the token's own payload — it
 * is NOT a signature check, so it is only used to decide WHEN to refresh.
 */
export function tokenExpiresWithin(token: string, skewSeconds: number): boolean {
  const exp = decodeExp(token);
  if (exp === null) return true;
  return exp * 1000 - Date.now() <= skewSeconds * 1000;
}

function decodeExp(token: string): number | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const json = Buffer.from(
      parts[1].replace(/-/g, "+").replace(/_/g, "/"),
      "base64",
    ).toString("utf8");
    const payload = JSON.parse(json) as { exp?: unknown };
    return typeof payload.exp === "number" ? payload.exp : null;
  } catch {
    return null;
  }
}
