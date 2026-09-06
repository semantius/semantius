import { NextResponse } from "next/server";
import { clearTokens } from "@/lib/auth/tokens";

export const runtime = "nodejs";

export async function POST(): Promise<NextResponse> {
  await clearTokens();
  return NextResponse.json({ ok: true });
}
