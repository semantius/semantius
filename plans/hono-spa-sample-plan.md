# Plan: Decoupled Sample — React SPA + Hono API (Neon / Supabase / PG18 OAuth + Drizzle)

## Goal

A **clean, decoupled** counterpart to the Next.js BFF sample: a browser React SPA and a standalone
Hono HTTP API, split into two folders, talking to a Semantius Core database with Drizzle. The SPA runs
the OAuth authorization-code + PKCE flow in the browser and calls the API with `Authorization: Bearer`.
The Hono API is a pure **resource server**: validate/forward the token, open a request-scoped transaction,
inject claims, run RLS-enforced Drizzle queries. Runs unchanged against the same three backends:

1. **PostgreSQL 18 native OAuth** (token authenticates the DB connection; DB validates) — the natural showcase here.
2. **Neon** (API verifies JWT, injects claims).
3. **Supabase** (API verifies JWT, injects claims) — **without** `@supabase/ssr` / `supabase-js`.

This sample exists to prove the data/auth layer is **framework-agnostic**: it vendors the *same* db layer
as the Next.js sample (schema + adapters + session — copied, not a shared package) and the same DB claims
contract; only the auth-transport + presentation tier differs.

## Prerequisite
Depends on **`foundation-dual-auth-plan.md`** being signed off first — the `session`-mode `semantius_authenticator` role + the `SET LOCAL ROLE authenticated` + claims contract (incl. the **mandatory session-adapter security requirements**) on the local pgdocker stack. The backend's mode is chosen by **`DB_AUTH_MODE = bearer | session`** (the host is just a connection string). The SPA is mode-agnostic (it only does OAuth + sends a bearer token).

## Folder layout — two self-contained folders (copy-paste portable)
```
examples/
  spa-frontend/        # Vite + React + TS SPA (browser PKCE, bearer to API, NO DB access)
  spa-hono-backend/    # Hono API; own package.json; vendors lib/db/ (schema + adapters + transport + jose verify)
```
- **No shared package.** Each folder is self-contained with its own `package.json` and vendors what it needs (matches the repo's existing example convention). `spa-hono-backend` vendors the *same* db layer as `examples/nextjs`; the duplication is the accepted price of copy-paste portability.
- The SPA has **no DB dependency at all** (no Drizzle/node-postgres in the browser bundle). It defines its own minimal API DTO / claims types locally (or copies a tiny `types.ts`) — it does not import the backend's db code.

## Architecture

### Frontend — `spa-frontend`
- **Vite + React + TypeScript**, SPA only (no SSR, no server). No DB access whatsoever.
- **OAuth**: browser authorization-code + **PKCE** via **`react-oauth2-code-pkce`** (`AuthProvider` + `useAuth()`; handles PKCE, refresh-token rotation, storage). `oauth4webapi` in-browser is the lower-level alternative.
  - **Assumed IdP constraints (same issuer as the Next sample; live-probed in review but NOT pinned in the repo — confirm with a milestone-0 spike):** `client_id=public-client` (NOT `test-client`, which is confidential and used only by the repo's headless `/getaccesstoken` mint), redirect URI must be **issuer-allow-listed**, and the discovery doc omits `code_challenge_methods_supported` → ensure the lib still sends **S256** (`react-oauth2-code-pkce` does; `oauth4webapi` needs an explicit override). Dev fallback: the `/getaccesstoken?client_id=test-client` mint (no refresh token).
- **Token storage**: access token in **memory** (React context), not localStorage. **Resolve the refresh-token tradeoff explicitly** (don't leave it to the lib's default, which is `localStorage`): either (a) **memory-only** access+refresh (re-login on reload — simplest, no JS-readable refresh token), or (b) a small **backend refresh-mediation endpoint** (httpOnly cookie). Configure `react-oauth2-code-pkce` to **not** use `localStorage`, or document the accepted XSS tradeoff. Don't contradict the "no refresh token in JS-readable storage" security note.
- **API calls**: a `fetch`/axios wrapper that reads the current access token from `useAuth()` and sets `Authorization: Bearer`. On **401 → refresh then retry**, else re-login.
- Pages: a users list + a permission-appropriate write (see RLS note).

### Backend — `spa-hono-backend`
- **Hono** on the **Node runtime** to start (raw TCP to Postgres needs Node; Workers can't do node-postgres TCP — see Open Questions). Note Bun/Deno/Workers portability as a stretch.
- Middleware chain (order matters):
  1. **CORS** (`hono/cors`): `origin` = **exact-match allowlist from `CORS_ORIGINS`** (never reflect an arbitrary `Origin`, never `'*'`), allow the `Authorization` header, `allowMethods: ['GET','POST','PUT','OPTIONS']` (the write path triggers an `OPTIONS` preflight). Bearer model needs **no cookies** → **`credentials: false`** (never combine `'*'` with credentials) → no CSRF surface.
  2. **`contextStorage()`** (`hono/context-storage`) — AsyncLocalStorage so reusable DAL/logging deep in the call stack can call `getDb()` without threading `c`. (Confirmed: Hono context alone is explicit-only; ambient cross-file access needs ALS — shared with the Next sample.)
  3. **Session middleware** (every request runs in a transaction, both modes), selected by `DB_AUTH_MODE`: resolve adapter → open connection → **`session` mode:** `db.transaction()` + `SET LOCAL ROLE authenticated` + `set_config('request.jwt.claims', json, true)` (LOCAL — claims injected before any rbac call, since `rbac.uid()` is STABLE/cached per tx); **`bearer` mode:** manual `BEGIN`/`COMMIT` serialized over the transport (pg-proxy has no `db.transaction()`). Run `fn`, `COMMIT`/`ROLLBACK`, put the db handle on the context store → `next()` → **always release/`.end()` in `finally`**. Wrapping bearer in a tx isn't required for single-statement correctness but gives uniform code, persists the `app.user_permissions` LOCAL cache across multi-statement requests, and is transaction-pooling-safe.
- **`session` mode (Neon / Supabase / local pgdocker)**: connect as the `semantius_authenticator` login role; the API is the **sole trust boundary**, so it **must follow the foundation's MANDATORY session-adapter security requirements** — verify with `jose` + remote JWKS, **pin `algorithms:['RS256']`** + `issuer` + **mandatory `audience`**, **fail closed** on any verify/JWKS failure (never inject from an unverified token); inject the **exact verified payload** (`role` pinned server-side), **only inside a tx** (throw otherwise); **refuse a superuser/owner connection at startup**. `rbac.uid()` does no signature checking for non-OAuth sessions (no `system_user` anti-spoof here).
- **`bearer` mode (PG18 OAUTHBEARER)**: the user's token flows **SPA → Hono → Postgres** and authenticates the OAUTHBEARER connection; the DB validates it (vendored `pg-oauthbearer.ts` via `pg-proxy`). The API need not verify the token itself (cheap `exp` pre-check optional). Cleanest demonstration of PG18 native OAuth. (PgBouncer doesn't passthrough OAUTHBEARER, so this is a direct connection in practice — the tx wrap is still the right uniform/robust default.)
- Routes: `GET /users` (RLS-enforced list, works for any provisioned user), `GET /me` (first-call **provisioning** via `public.get_userinfo()` — write path; the `User` role is auto-assigned by trigger), a permission-appropriate write (admin/first user for `user:manage`, or a self-scoped action).

### Vendored db layer — `spa-hono-backend/lib/db/` (same code as the Next sample, copied)
- Generated Drizzle schema, vendored via `deno task drizzlegen --output examples/spa-hono-backend/lib/db/schema`. **Latent generator bug** (same as Next sample): `fields.tableName` / `queue_table_events.tableName` are typed `integer` but reference a `text` PK (`examples/drizzle/src/schema/admin.ts:60,153`) — avoid those tables in the demo (`users`/`roles`/`user_roles` are unaffected); ideally fix the generator.
- **Adapter interface (byte-identical to the Next sample's §3 — same vendored file)**: `interface DbAdapter { runInSession(ctx: { token; claims: VerifiedClaims }, fn: (db: DbHandle) => Promise<T>): Promise<T> }` with two impls selected by `DB_AUTH_MODE` — `bearer` (vendored transport + pg-proxy + manual `BEGIN`/`COMMIT`) and `session` (node-postgres `Pool` as `semantius_authenticator` + `db.transaction()` [pins one pooled client] + `SET LOCAL ROLE authenticated` + `set_config` LOCAL; transaction-pooler-safe via node-postgres' default unnamed statements — no `name:`/`.prepare()`; `?sslmode=require` on managed, off localhost). Note: `prepare:false` is a postgres.js option, not node-postgres — don't use it.
- ALS-based `withSession()` / `getDb()` returning a **narrow common query surface** (`DbHandle`), since the pg-proxy db (bearer) and node-postgres tx (session) are different types.
- `jose` JWKS verification helper (`session` mode).

## Request-scoped session (backend)
- `contextStorage()` + `getContext().var.db`, or a `withSession` wrapper — same ALS-based `getDb()` the Next sample uses. Hono makes the **lifecycle** trivial (one middleware = one begin/commit); ALS handles **propagation**.

## RLS / provisioning (same contract as Next sample)
- **Provisioning is automatic**: `get_userinfo()` INSERTs the `users` row, firing the `AFTER INSERT` trigger `rbac.auto_assign_user_role()` (`apps/_core/migrations/0050_rbac_rls.sql:271-307`) which grants the `User` role (`user:read`+`public:read`); the **first** user in an empty DB also gets `Administrator` (`user:manage`,`admin`). No explicit role-assignment step.
- On first `GET /me`: call `get_userinfo()` (write path) — that's all.
- `GET /users` read works for any provisioned user. A `users` write needs `user:manage` → admin only (first user, or admin-promoted; `user_roles` writes are themselves admin-gated). Demo the write with the admin/first user or a self-scoped action — don't imply a normal user can write arbitrary `users` rows.

## Config / env
```
# spa-frontend (.env, VITE_ prefix — public)
VITE_OAUTH_ISSUER=https://oidc-test.semanti.us
VITE_OAUTH_CLIENT_ID=public-client
VITE_OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback   # must be issuer-allow-listed
VITE_API_BASE_URL=http://localhost:8788   # 8787 is taken by the oauth-hono-mcp sibling

# spa-hono-backend (.env)
DB_AUTH_MODE=bearer | session              # selects the adapter (NOT the host)
PORT=8788                                  # NOT 8787 (oauth-hono-mcp dev server uses 8787)
CORS_ORIGINS=http://localhost:3000
OAUTH_ISSUER / OAUTH_JWKS_URI / OAUTH_EXPECTED_AUD   # session-mode verification (aud check optional; off in DB by default)
# bearer mode: PG_HOST / PG_PORT / PG_DATABASE (token authenticates)
# session mode: DATABASE_URL=postgresql://semantius_authenticator:<pw>@host:port/db (pw from gitignored env, never committed; local: no sslmode; Neon & Supabase 6543: ?sslmode=require; node-postgres needs no prepare flag — unnamed statements, pooler-safe)
```

## Required token claims
Same contract as the Next sample (document in both READMEs): `role=authenticated` (Auth0/Clerk via custom claim — confirmed feasible on Auth0), `sub`, `iss`, `aud` (DB enforces only if `_settings.jwt_aud` is seeded — **off by default in pgdocker**), `exp`/`iat`, plus `email`/`name`/`given_name`/`family_name` for the profile.

## Security notes (README)
- **`session` mode connects as `semantius_authenticator`** — a `NOINHERIT NOSUPERUSER NOBYPASSRLS` gatekeeper, the exact analogue of Supabase's `authenticator`: it *enforces* RLS by `SET ROLE authenticated`, it does **not** bypass it. Created identically by the migrations on local/Neon/Supabase. **The RLS-bypass trap is the owner string** — never run `session` mode as the default `postgres`/project-owner connection (superuser → silently returns all rows). Assert `rolsuper`/`rolbypassrls` are false (foundation guardrail).
- Access token in memory, refresh via rotation; never refresh token in JS-readable storage.
- `session` mode: API MUST verify the JWT (pinned RS256 + `issuer` + mandatory `aud`) and **fail closed** before injecting; an unverified/forged `request.jwt.claims` would otherwise be trusted. Refuse a superuser/owner DB connection at startup.
- `bearer` mode: DB is authoritative for `sub` via `system_user`; client-spoofed claims ignored.
- CORS origin allowlist; HTTPS in prod; bearer model = no cookie CSRF, but tokens are XSS-exposed.

## Scalability & production caveats (README must state)
Sample-acceptable; honest caveats for production:
- **Pooler sizing.** `session` mode is transaction-pooler-safe (LOCAL `SET ROLE`/`set_config`), but the plans don't size it: set the app `Pool.max` ≤ the pooler's per-tenant budget; behind Supabase 6543 / Neon pooler in transaction mode. If the Hono API ever runs serverless (Workers/Lambda), use a small `Pool.max` (often 1) + the Neon serverless driver — a long-running Node server can use a normal pool. Set a short `idleTimeoutMillis`.
- **Per-request permission CTE** and **`bearer`-mode ceiling**: as in the foundation's "Scalability & production caveats" (bearer ≈ `max_connections` concurrent users, no pooling, per-request connect+SASL+possible JWKS fetch, serialized non-pipelined round-trips; the recursive permission CTE re-runs per request — production needs an app-side permission cache).
- **Refresh-token storms.** ~1h `exp` + many SPA clients ⇒ synchronized expiry can stampede the IdP at the hour boundary; add jitter / refresh-ahead in production.

## Open questions / risks
1. **Redirect URI / port contention.** The test issuer's redirect allow-list (probed) contains only fixed `localhost:3000` entries (`/oauth2_callback`, `/auth/oauth2_callback`); Vite's default 5173 is **not** allow-listed, and the Next sample also wants `:3000`. **Decisions:** run the SPA on `:3000` and the Hono API on **`:8788`** (NOT 8787 — that's the oauth-hono-mcp sibling, confirmed). Only one of {Next sample, this SPA} can hold `:3000`/the shared redirect at a time — run them separately, or register a dedicated public client + redirect. Confirm against the live issuer in the milestone-0 spike.
2. **PKCE discoverability.** `code_challenge_methods_supported` absent from discovery — `react-oauth2-code-pkce` sends S256 regardless (verify); `oauth4webapi` needs an explicit override.
3. **Hono runtime.** node-postgres + the OAUTHBEARER transport need raw TCP → Node runtime. Cloudflare Workers can't do that without Hyperdrive/neon-http; ALS on Workers needs `nodejs_compat`. Start on Node; flag Workers as non-trivial.
4. **Code sharing — decided: self-contained vendoring (no shared package).** Each folder has its own `package.json` and vendors its db layer (matches the existing example convention; copy-paste portable). Trade-off accepted: the db layer is duplicated between `examples/nextjs` and `examples/spa-hono-backend`; keep them in sync by hand + re-running `drizzlegen` into each. No `pnpm-workspace.yaml` change needed.
5. **pg18 connection pooling.** Per-user token connections can't be pooled across users; per-request connect for the sample (handshake cost) with `.end()` in `finally`.
6. **Refresh tokens in a pure SPA.** Rotation vs. a token-mediating refresh endpoint; document the chosen tradeoff.
7. **Frontend types — decided: local minimal types.** The SPA keeps its own small API DTO / claims types (copied, not imported) so it stays free of any DB/runtime deps. No cross-folder import.

## Implementation milestones
0. **Spike (gates BOTH samples): confirm the live browser OAuth flow** against `oidc-test.semanti.us` (public client id, redirect allow-list, PKCE/S256). **Hard exit criterion: confirm a usable refresh token is issued** (1h `exp` breaks the demo otherwise). Falls back to the `test-client` `/getaccesstoken` mint if not. De-risks the assumptions both samples share.
1. Scaffold two self-contained folders: `examples/spa-frontend` (Vite/React/TS) and `examples/spa-hono-backend` (Hono/Node/TS, port **8788**, own `package.json`). Vendor the db layer into `spa-hono-backend/lib/db/` via `drizzlegen --output examples/spa-hono-backend/lib/db/schema`.
2. Backend: Hono app + CORS + `contextStorage()` + session middleware; wire the two vendored adapters.
3. Backend: `session` mode (jose verify + `SET LOCAL ROLE authenticated` + `set_config` claims-first in a tx) and `bearer` mode (manual `BEGIN`/`COMMIT` tx), each tested against its backend (local pgdocker exercises both via `DB_AUTH_MODE`).
4. Backend: `GET /users`, `GET /me` (provisioning — role auto-assigned by trigger), permission-appropriate write.
5. Frontend: `AuthProvider` (`public-client`, allow-listed redirect, S256), login/callback, in-memory token, bearer fetch wrapper with 401→refresh.
6. Frontend: users list + write UI.
7. End-to-end CORS wiring; run SPA on an allow-listed origin/port.
8. READMEs for both folders: env (incl. `DB_AUTH_MODE`), **required-claims table**, security/trust model, provisioning+role requirement, how the db layer is vendored (same as the Next sample), run instructions. **MUST include the per-backend trust model:** `bearer`/self-hosted verifies the JWT **in the DB** (`pg_oidc_validator`, RS256). **`session` mode is app-verify / one-gate on *every* backend — Supabase AND Neon** — because no off-the-shelf RS256 in-DB verifier exists (`pg_session_jwt` is EdDSA-only; Supabase can't install it anyway), so **no additional token validation can be added in the database** in `session` mode. The app's jose verification + the `semantius_authenticator` password are the protection; DB-enforced verification is `bearer`. **Also warn:** on a *fresh* DB the **first provisioned user becomes `Administrator`** (auto-assign trigger) — don't point a shared/multi-user demo at the public token-minting issuer; use per-developer DBs or seed an admin out-of-band.
9. Validate both modes against their backends (prove the Supabase-pooler/session round-trip and the bearer token pass-through), referencing the foundation as the gate.
10. **End-to-end browser verification (REQUIRED — the same tests the Next.js sample passed; a typecheck/build is NOT sufficient sign-off).** The Next.js sample (`examples/nextjs`) is the proven template — its full flow (home → Log in → issuer Sign In → callback/code-exchange → RLS read → `user:manage` write) was driven through a real Chrome browser and both modes verified; do the equivalent here.
    - **Boot both servers**: the Hono API on `:8788` and the Vite SPA on `:3000` (an issuer-allow-listed origin). Only one of {Next sample, this SPA} can hold `:3000` at a time → **stop the Next dev server first** (Open Question 1).
    - **Drive a real browser with `agent-browser`** (installed: `agent-browser@0.27.0`; the `open` → `snapshot -i` → `click`/`fill` → `get text`/`get url` loop — accessibility-tree `@eN` refs keep agent context to ~200–400 tokens, no DOM dumps). **A real browser is REQUIRED, not curl**: the SPA is a client-side React app that runs the in-browser PKCE flow and holds the access token in **JS memory** — curl can't execute it. (For the Next.js BFF the reason was different but equally disqualifying for curl: its tokens are in `Secure` httpOnly cookies, which curl won't send to `http://localhost`; Chrome treats localhost as a secure context and does.)
    - **The flow to script**: `agent-browser open http://localhost:3000` → click **Log in** → issuer Sign In form (test creds `user1` / `password123`; `user3` / `password789` = `admin@test.com`) → SPA `/oauth2_callback` exchanges the code (PKCE, **no secret**) and holds the token in memory → the users list renders from `GET /users` (CORS preflight + `Authorization: Bearer`, RLS-enforced) → exercise the `user:manage` write (succeeds as `user1` = first user = Administrator; assert a plain user is RLS-blocked). Verify with `agent-browser get url` / `get text`.
    - **Both modes through the real UI**: run the above with the backend on **`DB_AUTH_MODE=bearer`** (SPA → Hono → PG18 OAUTHBEARER, DB validates the token) and again on **`DB_AUTH_MODE=session`** (Hono jose-verifies the **real browser-issued `public-client` token** — `aud=["public-client","api://default"]`, RS256/iss/aud — connects as `semantius_authenticator` over SCRAM, injects claims). Restart the backend + re-login between modes (the SPA token is in memory). Clean up any demo write afterward.
    - **Confirm CORS**: the `OPTIONS` preflight + `Authorization` header are allowed for the `:3000` origin (exact-match `CORS_ORIGINS`, `credentials:false`).
    - **Headless DB-layer smoke** (no browser; both local stacks 5432 + 5433 — mirror `examples/nextjs/scripts/`): `scripts/smoke-db.ts <bearer|session>` mints a token and drives the **vendored** adapters through `withSession` (provision via `get_userinfo` + `/users` read under RLS); `scripts/smoke-guard.ts` asserts the session adapter **refuses a superuser/owner connection at startup**. Both green on both stacks.
    - **Sign-off** = both modes green **through the browser** AND the headless smokes green on both local stacks. Neon/Supabase get the same browser + smoke treatment once credentials are available (milestone 9).

## Validation status (built 2026-06-09)

Both folders built under `examples/`: `spa-hono-backend` (Hono/Node, port 8788) and `spa-frontend` (Vite/React, port 3000).

| Milestone | Status |
|---|---|
| 0 — OAuth spike | **confirmed** (shared with the Next sample; re-confirmed live via the SPA browser flow — `public-client`, allow-listed `:3000/oauth2_callback`, **S256 forced**, refresh grant). |
| 1 — scaffold both folders + vendor db layer | **done.** `lib/db` + `lib/dal` copied byte-identical from `examples/nextjs`; schema regenerated via `deno task drizzlegen --output examples/spa-hono-backend/lib/db/schema` (functionally identical — one non-semantic column reorder in `queue_table_events`). |
| 2 — Hono app + CORS + contextStorage + session middleware | **done** (`src/server.ts`, `src/middleware/session.ts`; both adapters wired via `DB_AUTH_MODE`; startup superuser guard). |
| 3 — session + bearer modes | **done**, both exercised against local pgdocker via `DB_AUTH_MODE`. |
| 4 — routes | **done**: `GET /me` (provision), `GET /users` (RLS read), `PUT /me/display-name` (`user:manage` write). |
| 5 — frontend auth | **done**: **`react-oauth2-code-pkce`** (the plan's named library) wrapped in a thin `AuthProvider`/`useAuth()`, S256, **tokens in `localStorage` (survives F5)**, proactive token refresh. |
| 6 — frontend UI + routing | **done**: **TanStack Router** (code-based route tree) — root layout/nav + `/`, `/users`, `/oauth2_callback`; `/users` is **auth-guarded via `beforeLoad`** (redirects `unauthenticated` → `/`, allows `loading` through), live `useAuth()` injected into the router context. **Deep-link preservation:** the guard stashes the attempted href in `sessionStorage` (survives the external-IdP round-trip; a search param wouldn't) and the callback restores it exactly via `router.history.replace()` — query/hash included — falling back to a single named default `/users`. No hardcoded return. Home (status + backend-mode probe), Users list + write form. |
| 7 — CORS wiring | **done**: exact-match `CORS_ORIGINS` allowlist, `credentials:false`, `Authorization`+`PUT` allowed; preflight 204 verified. |
| 8 — READMEs | **done** for both folders (env, claims table, per-backend trust model, first-user-Administrator warning, vendoring note, run instructions). |
| typecheck/build | backend `tsc` green; SPA `tsc + vite build` green. |
| 9 — headless DB-layer smokes | **green on BOTH local stacks** (CLI 5432 + ext 5433): `smoke-db bearer`, `smoke-db session` (jose RS256/iss/aud verified), `smoke-guard` (superuser connection refused). |
| 10 — **full browser E2E (REQUIRED)** | **PROVEN in a real Chrome browser** (agent-browser), **both modes**: home(mode badge) → Log in → issuer Sign In (`user1`/`password123`) → `/oauth2_callback` PKCE/S256 exchange (react-oauth2-code-pkce) → `/users` RLS read → `user:manage` write **succeeds** as user1 (admin/first user); a non-admin (`user2`) is correctly **RLS-blocked**. **TanStack `beforeLoad` guard + deep-link return verified**: direct `/users?probe=1` while signed out → redirect to `/`, and after sign-in it returns to `/users?probe=1` (destination + query preserved, not a hardcode); plain login from Home → default `/users`. CORS preflight + `Authorization` confirmed for `:3000`. **Reload (F5) keeps the session** (tokens rehydrated from `localStorage`, guard allows through); Sign out → redirect to `/`, tokens cleared. Demo writes cleaned up. |
| 9 — Neon / Supabase | **pending** (credentials). |

### Open questions — resolved
1. **Port contention** — SPA on `:3000` (strictPort), API on **`:8788`**. Confirmed no Next server held `:3000` during the run.
2. **PKCE discoverability** — discovery omits `code_challenge_methods_supported`; moot for the SPA because `react-oauth2-code-pkce` does **no discovery** (explicit endpoints) and always sends **S256**. Verified in the live redirect URL (`code_challenge_method=S256`).
4. **Code sharing** — self-contained vendoring (no shared package); `lib/db`+`lib/dal` duplicated, kept in sync by hand. No `pnpm-workspace.yaml` change (it only globs `packages/*`).
6. **Refresh tokens in a pure SPA** — **`react-oauth2-code-pkce` with `localStorage`** (the plan's named library). The session **survives F5** and the lib refreshes the access token proactively. The plan's original "never a refresh token in JS-readable storage" note was overstated for a *decoupled* SPA: an httpOnly cookie/BFF doesn't stop in-session XSS abuse (a compromised client acts as the user regardless) — what storage governs is *persistence beyond the XSS window*, which we bound with refresh-token rotation + short access-token TTL; the real defense is preventing XSS (CSP). A BFF was rejected because it re-couples the SPA to a stateful server (defeating the decoupling) and duplicates the Next sample. (An earlier build used `oauth4webapi` memory-only, but that re-prompts on every reload — unacceptable for a SPA, and iframe silent-renew is dead to third-party-cookie blocking.) Documented in the SPA README's "Token storage & the security tradeoff".
7. **Frontend types** — local minimal DTOs (`src/types.ts`), no DB/runtime import.
