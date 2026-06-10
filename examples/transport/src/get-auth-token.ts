// =============================================================================
// get-auth-token.ts — obtain the OAuth access token the examples authenticate
// with (SASL OAUTHBEARER). Shared, vendored building block for the examples.
// =============================================================================
//
// THIS IS THE TEST IMPLEMENTATION. It mints a throwaway access token for a test
// user from the public test OIDC issuer (which mints tokens for anyone, with no
// login — it holds no secrets and exists only to exercise the OAuth path).
//
//   >>> In a real app, REPLACE THE BODY of getAuthToken() <<<
//
// with however you obtain the *current user's* access token — read it from the
// active session, your OIDC client / auth provider, an incoming Authorization
// header, etc. — and return that JWT string. The transport only needs the token;
// it does not care how you got it. Everything else in the examples stays the same.
//
// Test config via env (defaults in parentheses):
//   ISSUER (https://oidc-test.semanti.us)  USER_ID (user3 = admin@test.com)  CLIENT_ID (test-client)
// =============================================================================

/** Return an OAuth access token (JWT) to present to PostgreSQL over OAUTHBEARER. */
export async function getAuthToken(): Promise<string> {
  const issuer = process.env.ISSUER ?? "https://oidc-test.semanti.us";
  const userId = process.env.USER_ID ?? "user3"; // user3 = admin@test.com (the Administrator)
  const clientId = process.env.CLIENT_ID ?? "test-client";

  console.log(`Minting token for "${userId}" from ${issuer} …`);

  const url = `${issuer}/getaccesstoken?user_id=${encodeURIComponent(
    userId,
  )}&client_id=${encodeURIComponent(clientId)}`;
  const res = await fetch(url, {
    headers: { "user-agent": "curl/8.0", accept: "*/*" },
  });
  if (!res.ok) throw new Error(`token mint failed: HTTP ${res.status}`);
  let body = (await res.text()).trim();
  if (body.startsWith("{")) body = JSON.parse(body).access_token ?? "";
  if (body.split(".").length !== 3) {
    throw new Error(`issuer did not return a JWT (got: ${body.slice(0, 60)}…)`);
  }
  return body;
}
