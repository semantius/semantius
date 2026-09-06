import { NextResponse, type NextRequest } from "next/server";
import { exchangeCode } from "@/lib/auth/oauth";
import { resolveSessionContext } from "@/lib/auth/context";
import { setTokens, takeLoginState } from "@/lib/auth/tokens";
import { withSession } from "@/lib/db/session";
import { provisionCurrentUser } from "@/lib/dal/users";

// Path is issuer-allow-listed: /oauth2_callback (NOT an arbitrary /api path).
export const runtime = "nodejs";

export async function GET(req: NextRequest): Promise<NextResponse> {
  const login = await takeLoginState();
  if (!login) return fail("missing or expired login state — start over at /api/auth/login");

  let tokens;
  try {
    tokens = await exchangeCode({
      callbackParams: req.nextUrl.searchParams,
      expectedState: login.state,
      codeVerifier: login.codeVerifier,
      expectedNonce: login.nonce,
    });
  } catch (err) {
    return fail(`token exchange failed: ${err instanceof Error ? err.message : String(err)}`);
  }

  await setTokens({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token,
    expiresIn: typeof tokens.expires_in === "number" ? tokens.expires_in : undefined,
  });

  // First-login provisioning (an INSERT): open a write session with the fresh
  // token and call public.get_userinfo() so the users row exists (and the User /
  // first-user-Administrator roles are auto-assigned) before the first RLS read.
  // Non-fatal: the write action also provisions defensively.
  try {
    const ctx = await resolveSessionContext(tokens.access_token);
    await withSession(ctx, provisionCurrentUser);
  } catch (err) {
    console.error("post-login provisioning failed:", err instanceof Error ? err.message : err);
  }

  const dest = login.returnTo.startsWith("/") ? login.returnTo : "/users";
  return NextResponse.redirect(new URL(dest, req.nextUrl.origin));
}

function fail(message: string): NextResponse {
  // Never log tokens or echo them into URLs.
  return NextResponse.json({ error: message }, { status: 400 });
}
