export type Bindings = {
  // One Neon API key per Neon org alias: NEON_API_KEY_<ALIAS> (see neon-org.ts)
  NEON_API_KEY_PAID?: string;
  NEON_API_KEY_FREE?: string;
  NEON_PROVISIONER_API_KEY?: string;
  ASSETS?: Fetcher;
};
