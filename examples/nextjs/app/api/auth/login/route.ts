import { NextResponse, type NextRequest } from "next/server";
import * as oauth from "oauth4webapi";
import { buildAuthorizationUrl } from "@/lib/auth/oauth";
import { setLoginState } from "@/lib/auth/tokens";

export const runtime = "nodejs";

export async function GET(req: NextRequest): Promise<NextResponse> {
  const returnToParam = req.nextUrl.searchParams.get("returnTo");
  const returnTo = returnToParam && returnToParam.startsWith("/") ? returnToParam : "/users";

  // PKCE verifier + CSRF state + replay nonce — stashed in a short-lived httpOnly
  // cookie (Lax so it survives the IdP redirect back).
  const codeVerifier = oauth.generateRandomCodeVerifier();
  const codeChallenge = await oauth.calculatePKCECodeChallenge(codeVerifier);
  const state = oauth.generateRandomState();
  const nonce = oauth.generateRandomNonce();

  await setLoginState({ state, nonce, codeVerifier, returnTo });

  const url = await buildAuthorizationUrl({ codeChallenge, state, nonce });
  return NextResponse.redirect(url);
}
