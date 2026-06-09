// =============================================================================
// AuthContext — thin wrapper over `react-oauth2-code-pkce`, the standard SPA
// approach to browser OAuth (authorization-code + PKCE, no secret).
//
// The library owns the whole token lifecycle: it builds the authorize URL (S256
// always — it never relies on the issuer advertising `code_challenge_methods`),
// exchanges the `?code=` on the redirect page, **persists tokens in localStorage**
// (so the session survives an F5 / browser restart), and **refreshes the access
// token proactively** before expiry using the refresh token.
//
// TOKEN STORAGE / SECURITY (resolved tradeoff — see SPA README):
//   For a *decoupled* SPA + stateless bearer API, tokens live in the browser
//   (localStorage). XSS is the residual risk — but XSS already means the attacker
//   runs as your client (an httpOnly cookie wouldn't stop in-session abuse). What
//   storage actually governs is *persistence beyond the XSS window* (a stolen
//   refresh token), which we bound with refresh-token rotation + a short
//   access-token TTL. The real defense is preventing XSS (strict CSP, etc.), not
//   hiding tokens behind a BFF — a BFF would re-couple the SPA to a stateful
//   server and defeat the point of this decoupled sample.
//
// We expose a small, app-shaped `useAuth()` over the library's context so the
// pages/API client don't depend on the library's surface directly.
// =============================================================================

import { useContext, type ReactNode } from "react";
import {
  AuthContext as LibAuthContext,
  AuthProvider as LibAuthProvider,
  type TAuthConfig,
} from "react-oauth2-code-pkce";

const authConfig: TAuthConfig = {
  clientId: import.meta.env.VITE_OAUTH_CLIENT_ID,
  authorizationEndpoint: import.meta.env.VITE_OAUTH_AUTHORIZATION_ENDPOINT,
  tokenEndpoint: import.meta.env.VITE_OAUTH_TOKEN_ENDPOINT,
  redirectUri: import.meta.env.VITE_OAUTH_REDIRECT_URI,
  scope: "openid profile email",
  // Persist across reloads (survives F5). Use 'session' to scope to the tab.
  storage: "local",
  // Decode the JWTs so we can show the signed-in user (display only).
  decodeToken: true,
  // Don't bounce to the issuer on first load — the user clicks "Log in".
  autoLogin: false,
  // Strip ?code= from the URL after the exchange (default, stated for clarity).
  clearURL: true,
};

export function AuthProvider({ children }: { children: ReactNode }) {
  return <LibAuthProvider authConfig={authConfig}>{children}</LibAuthProvider>;
}

export type AuthStatus = "loading" | "authenticated" | "unauthenticated";

export interface DisplayClaims {
  sub?: string;
  email?: string;
  name?: string;
}

export interface AuthValue {
  status: AuthStatus;
  claims: DisplayClaims | null;
  error: string | null;
  token: string | null;
  login: () => void;
  logout: () => void;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

export function useAuth(): AuthValue {
  const { token, tokenData, idTokenData, logIn, logOut, error, loginInProgress } =
    useContext(LibAuthContext);

  const source = idTokenData ?? tokenData;
  const claims: DisplayClaims | null = source
    ? { sub: str(source.sub), email: str(source.email), name: str(source.name) }
    : null;

  const status: AuthStatus = loginInProgress
    ? "loading"
    : token
      ? "authenticated"
      : "unauthenticated";

  return {
    status,
    claims,
    error: error ?? null,
    token: token || null,
    login: () => logIn(),
    logout: () => logOut(),
  };
}
