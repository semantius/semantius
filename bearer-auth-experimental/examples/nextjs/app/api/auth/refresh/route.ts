import { NextResponse, type NextRequest } from "next/server";
import { ensureFreshToken } from "@/lib/auth/refresh";

export const runtime = "nodejs";

// Used by RSC pages that can't write cookies during render: when the access token
// is expiring, they redirect here, we refresh (writing new cookies), then bounce
// back to `returnTo`. Falls through to /api/auth/login if refresh isn't possible.
export async function GET(req: NextRequest): Promise<NextResponse> {
  const raw = req.nextUrl.searchParams.get("returnTo");
  const returnTo = raw && raw.startsWith("/") ? raw : "/users";
  const origin = req.nextUrl.origin;

  const token = await ensureFreshToken();
  if (token) {
    return NextResponse.redirect(new URL(returnTo, origin));
  }
  const loginUrl = new URL("/api/auth/login", origin);
  loginUrl.searchParams.set("returnTo", returnTo);
  return NextResponse.redirect(loginUrl);
}
