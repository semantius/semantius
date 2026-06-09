/** @type {import('next').NextConfig} */
const nextConfig = {
  // The vendored OAUTHBEARER transport, node-postgres, and AsyncLocalStorage are
  // all Node-only. Every DB-touching route already sets `export const runtime =
  // 'nodejs'`; we also keep `pg` external so Next doesn't try to bundle it.
  serverExternalPackages: ["pg", "pg-types"],
  // This sample lives inside a larger monorepo; scope file tracing to itself so
  // Next doesn't pick the repo-root lockfile as the workspace root.
  outputFileTracingRoot: import.meta.dirname,
};

export default nextConfig;
