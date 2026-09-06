import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// SPA on :3000 — the issuer-allow-listed origin/redirect. strictPort so we fail
// loudly rather than silently moving to :3001 (which is NOT allow-listed and would
// break the OAuth redirect). appType:'spa' (default) serves index.html for
// /oauth2_callback and /users (client-side routing).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    strictPort: true,
  },
  preview: {
    port: 3000,
    strictPort: true,
  },
});
