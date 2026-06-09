// =============================================================================
// refresh.ts — the 401-avoidance path. Access tokens are ~1h; without refresh the
// demo breaks after an hour. Callable only from route handlers / server actions
// (it writes cookies).
// =============================================================================

import { refreshTokens } from "./oauth";
import {
  clearTokens,
  getAccessToken,
  getRefreshToken,
  setTokens,
  tokenExpiresWithin,
} from "./tokens";

/**
 * Return a usable (non-expiring-soon) access token, refreshing it first if needed.
 *   - token still fresh           -> return it
 *   - expiring soon + refresh tok -> refresh, persist new tokens, return new one
 *   - refresh fails / none        -> clear tokens, return null (caller -> login)
 */
export async function ensureFreshToken(skewSeconds = 60): Promise<string | null> {
  const token = await getAccessToken();
  if (token && !tokenExpiresWithin(token, skewSeconds)) return token;

  const refreshToken = await getRefreshToken();
  if (!refreshToken) {
    // No way to refresh. If we still have a (possibly soon-to-expire) token, hand
    // it back so a single request can still proceed; otherwise signal "log in".
    return token;
  }

  try {
    const t = await refreshTokens(refreshToken);
    await setTokens({
      accessToken: t.access_token,
      refreshToken: t.refresh_token ?? refreshToken,
      expiresIn: typeof t.expires_in === "number" ? t.expires_in : undefined,
    });
    return t.access_token;
  } catch {
    await clearTokens();
    return null;
  }
}
