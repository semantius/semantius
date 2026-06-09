// =============================================================================
// useApi() — a fetch wrapper that attaches the access token as
// `Authorization: Bearer`. Mode-agnostic: the SPA never knows or cares whether
// the API runs in bearer or session mode.
//
// react-oauth2-code-pkce refreshes the access token PROACTIVELY (before expiry),
// so the `token` from useAuth() is kept fresh and an expiry-401 is rare. A 401
// here therefore means the session is genuinely gone → the caller surfaces a
// re-login (rather than the reactive refresh-then-retry the hand-rolled client did).
//
// Any request carrying an Authorization header is a "non-simple" CORS request, so
// the browser sends an OPTIONS preflight (for GET too, not only the PUT write) —
// the Hono API's CORS allowlist handles it (Authorization allowed, credentials:false).
//
// `token` is a primitive, so this fetch wrapper is referentially stable until the
// token actually changes (a refresh) — safe to use as an effect dependency.
// =============================================================================

import { useCallback } from "react";
import { useAuth } from "../auth/AuthContext";

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? "";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export type ApiFetch = <T>(path: string, init?: RequestInit) => Promise<T>;

export function useApi(): ApiFetch {
  const { token } = useAuth();

  return useCallback<ApiFetch>(
    async <T>(path: string, init?: RequestInit): Promise<T> => {
      const res = await fetch(`${API_BASE}${path}`, {
        ...init,
        headers: {
          ...(init?.headers ?? {}),
          ...(init?.body ? { "Content-Type": "application/json" } : {}),
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
      });

      const data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
      if (res.status === 401) {
        const msg =
          typeof data.message === "string"
            ? data.message
            : "Your session has expired. Please log in again.";
        throw new ApiError(401, msg);
      }
      if (!res.ok) {
        const msg = typeof data.message === "string" ? data.message : `HTTP ${res.status}`;
        throw new ApiError(res.status, msg);
      }
      return data as T;
    },
    [token],
  );
}
