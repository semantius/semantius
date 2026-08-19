import type { Bindings } from "./types.js";

/**
 * Neon org aliases. Each tenant project lives in one Neon org; the matching
 * API key is provided as NEON_API_KEY_<ALIAS> (NEON_API_KEY_FREE, NEON_API_KEY_PAID, ...).
 */
export const NEON_ORG_IDS = ["free", "paid"] as const;

export type NeonOrgId = (typeof NEON_ORG_IDS)[number];

export function isNeonOrgId(value: unknown): value is NeonOrgId {
  return typeof value === "string" && (NEON_ORG_IDS as readonly string[]).includes(value);
}

type NeonApiKeyEnvName = `NEON_API_KEY_${Uppercase<NeonOrgId>}`;

export function neonApiKeyEnvName(neonOrgId: NeonOrgId): NeonApiKeyEnvName {
  return `NEON_API_KEY_${neonOrgId.toUpperCase() as Uppercase<NeonOrgId>}`;
}

export type ResolveNeonApiKeyResult =
  | { ok: true; apiKey: string; neonOrgId: NeonOrgId }
  | { ok: false; status: 400 | 500; error: string };

/**
 * Resolve the Neon API key for a request's `neon_org_id`.
 * 400 when neon_org_id is missing/unknown, 500 when the env var is not set.
 */
export function resolveNeonApiKey(
  env: Bindings | undefined,
  neonOrgId: unknown,
): ResolveNeonApiKeyResult {
  if (!isNeonOrgId(neonOrgId)) {
    return {
      ok: false,
      status: 400,
      error: `neon_org_id is required and must be one of: ${NEON_ORG_IDS.join(", ")}`,
    };
  }

  const envName = neonApiKeyEnvName(neonOrgId);
  const apiKey = env?.[envName];

  if (!apiKey) {
    return {
      ok: false,
      status: 500,
      error: `${envName} environment variable must be set`,
    };
  }

  return { ok: true, apiKey, neonOrgId };
}
