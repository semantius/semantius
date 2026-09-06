"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { resolveSessionContext } from "@/lib/auth/context";
import { ensureFreshToken } from "@/lib/auth/refresh";
import { clearTokens } from "@/lib/auth/tokens";
import { withSession } from "@/lib/db/session";
import {
  getUserByExternalId,
  provisionCurrentUser,
  updateDisplayName,
} from "@/lib/dal/users";

export interface ActionResult {
  ok: boolean;
  message: string;
}

/**
 * Write demo (server action). Updates the signed-in user's display name. Writing
 * to `users` requires the `user:manage` permission (the Administrator role); a
 * plain `User` is correctly RLS-blocked. On a FRESH per-developer DB the first
 * user to log in becomes Administrator, so this succeeds for them.
 */
export async function updateMyDisplayName(
  _prev: ActionResult | null,
  formData: FormData,
): Promise<ActionResult> {
  const displayName = String(formData.get("displayName") ?? "").trim();
  if (!displayName) return { ok: false, message: "Display name is required." };
  if (displayName.length > 200) {
    return { ok: false, message: "Display name is too long (max 200 chars)." };
  }

  // Refresh inline if the token is expiring (server actions can write cookies).
  const token = await ensureFreshToken();
  if (!token) return { ok: false, message: "You are not signed in. Please log in again." };

  let ctx;
  try {
    ctx = await resolveSessionContext(token);
  } catch {
    return {
      ok: false,
      message: "Your session token failed verification. Please log in again.",
    };
  }

  try {
    const updated = await withSession(ctx, async () => {
      await provisionCurrentUser(); // idempotent; ensures the row exists
      const me = await getUserByExternalId(ctx.claims.sub);
      if (!me) return 0;
      return updateDisplayName(me.id, displayName);
    });

    if (updated === 0) {
      return {
        ok: false,
        message:
          "Blocked by RLS: writing to users needs the user:manage permission " +
          "(the Administrator role). On a fresh per-developer DB the FIRST user to " +
          "log in becomes Administrator; a non-admin is correctly denied.",
      };
    }

    revalidatePath("/users");
    return { ok: true, message: `Updated your display name to “${displayName}”.` };
  } catch (err) {
    return {
      ok: false,
      message: `Update failed: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
}

export async function logoutAction(): Promise<void> {
  await clearTokens();
  redirect("/");
}
