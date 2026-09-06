// =============================================================================
// oauth.ts — vendor-agnostic OAuth 2.0 / OIDC client (authorization-code + PKCE,
// NO client secret) built on oauth4webapi. Discovery is memoized.
//
// The test issuer's discovery doc OMITS `code_challenge_methods_supported`, so
// oauth4webapi will not auto-apply PKCE — we FORCE S256 on the authorization URL
// ourselves (the endpoint accepts S256; it just isn't advertised).
// =============================================================================

import * as oauth from "oauth4webapi";

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required environment variable ${name}`);
  return v;
}

const SCOPE = "openid profile email";

// Config is read LAZILY (inside accessors), never at module top-level — otherwise
// `next build` (which evaluates route modules) would throw before any env is set.
interface OAuthConfig {
  issuerUrl: URL;
  clientId: string;
  redirectUri: string;
}
let cfg: OAuthConfig | null = null;
function config(): OAuthConfig {
  if (!cfg) {
    cfg = {
      issuerUrl: new URL(requireEnv("OAUTH_ISSUER")),
      clientId: requireEnv("OAUTH_CLIENT_ID"),
      redirectUri: requireEnv("OAUTH_REDIRECT_URI"),
    };
  }
  return cfg;
}

function client(): oauth.Client {
  return { client_id: config().clientId };
}
// Public client: no secret, no client authentication at the token endpoint.
const clientAuth: oauth.ClientAuth = oauth.None();

let asPromise: Promise<oauth.AuthorizationServer> | null = null;
/** Memoized OIDC discovery (`/.well-known/openid-configuration`). */
export function getAuthorizationServer(): Promise<oauth.AuthorizationServer> {
  if (!asPromise) {
    const { issuerUrl } = config();
    asPromise = (async () => {
      const res = await oauth.discoveryRequest(issuerUrl, { algorithm: "oidc" });
      return oauth.processDiscoveryResponse(issuerUrl, res);
    })().catch((err) => {
      asPromise = null; // let a later request retry instead of caching the failure
      throw err;
    });
  }
  return asPromise;
}

export interface AuthorizationUrlInput {
  codeChallenge: string;
  state: string;
  nonce: string;
}

/** Build the issuer authorization URL with PKCE S256 forced. */
export async function buildAuthorizationUrl(input: AuthorizationUrlInput): Promise<URL> {
  const as = await getAuthorizationServer();
  if (!as.authorization_endpoint) {
    throw new Error("issuer discovery is missing authorization_endpoint");
  }
  const { clientId, redirectUri } = config();
  const url = new URL(as.authorization_endpoint);
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("code_challenge", input.codeChallenge);
  url.searchParams.set("code_challenge_method", "S256"); // FORCED (see header)
  url.searchParams.set("state", input.state);
  url.searchParams.set("nonce", input.nonce);
  return url;
}

export interface ExchangeInput {
  callbackParams: URLSearchParams;
  expectedState: string;
  codeVerifier: string;
  expectedNonce: string;
}

/** Validate the callback (state/CSRF), then exchange the code with the PKCE
 * verifier (no secret) and verify the id_token nonce (replay). */
export async function exchangeCode(input: ExchangeInput): Promise<oauth.TokenEndpointResponse> {
  const as = await getAuthorizationServer();
  const c = client();
  const validated = oauth.validateAuthResponse(
    as,
    c,
    input.callbackParams,
    input.expectedState,
  );
  const res = await oauth.authorizationCodeGrantRequest(
    as,
    c,
    clientAuth,
    validated,
    config().redirectUri,
    input.codeVerifier,
  );
  return oauth.processAuthorizationCodeResponse(as, c, res, {
    expectedNonce: input.expectedNonce,
  });
}

/** Exchange a refresh token for a fresh access token (issuer advertises the
 * refresh_token grant). */
export async function refreshTokens(refreshToken: string): Promise<oauth.TokenEndpointResponse> {
  const as = await getAuthorizationServer();
  const c = client();
  const res = await oauth.refreshTokenGrantRequest(as, c, clientAuth, refreshToken);
  return oauth.processRefreshTokenResponse(as, c, res);
}
