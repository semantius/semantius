# Plan: Vendor-Agnostic Next.js Sample (Neon / Supabase / PG18 OAuth + Drizzle)

## Goal

A Next.js (App Router) sample app that talks to a Semantius Core database with Drizzle,
authenticating users via OAuth (authorization-code + PKCE, no client secret) and running every
request inside a request-scoped transaction whose JWT claims are injected so RLS/RBAC enforces
per-user access. It must run unchanged against three backends:

1. **PostgreSQL 18 native OAuth** (local pgdocker stack; token authenticates the DB connection via SASL OAUTHBEARER; the `pg_oidc_validator` publishes `request.jwt.claims`).
2. **Neon** (standard connection string; app injects claims).
3. **Supabase** (standard connection string; app injects claims) — **without** `@supabase/ssr` or `supabase-js`.

## What the repo already gives us (verified)

- **Generated Drizzle schema**: `examples/drizzle/src/schema/` (barrel `index.ts`, generated `admin.ts`), produced by `deno task drizzlegen` (`packages/cli/commands/drizzlegen.ts`). Tables: `users`, `roles`, `user_roles`, `permissions`, etc. → reuse as-is.
- **OAUTHBEARER transport**: `examples/transport/src/pg-oauthbearer.ts` — hand-rolled PG v3 wire client doing SASL OAUTHBEARER. Single connection, no pool, no TLS, **no interactive transaction API** (but `BEGIN`/`COMMIT` can be issued as serialized queries).
- **Drizzle-over-transport**: `examples/drizzle/src/drizzle-proxy.ts` uses `drizzle-orm/pg-proxy` (one query callback; pg-proxy does **not** expose `db.transaction()`).
- **DB-side claims contract** (`apps/_core/migrations/0030_rbac_functions.sql`):
  - `rbac.uid()` accepts **both** Neon style (individual `request.jwt.claim.*` GUCs) **and** Supabase/PG18 style (single `request.jwt.claims` JSON blob, auto-normalized).
  - **PG18 hardening**: when `system_user LIKE 'oauth:%'`, the DB-validated `sub` is authoritative and overrides any client-supplied claims.
  - **Every request runs in an explicit transaction, on all three backends.** App-set context uses `set_config(..., true)` = transaction-LOCAL: on a pooled (Neon/Supabase) connection it MUST be inside `db.transaction()` to be scoped/auto-cleared. PG18 is technically *correct* without a tx on a direct single-statement connection (validator publishes claims at session scope, `system_user` is authoritative — `examples/drizzle/src/list-users.ts` runs plain queries), **but we wrap it too** — for uniform code, so the `app.user_permissions` LOCAL cache survives multi-statement requests, and to be safe behind transaction-pooling poolers (PgBouncer / Supabase 6543). pg-proxy has no `db.transaction()`, so the pg18 tx is manual `BEGIN`/`COMMIT` serialized over the transport, with `ROLLBACK` on error. (Note: PgBouncer doesn't passthrough OAUTHBEARER today, so PG18 is direct in practice — the tx is still the right robust/uniform default.)
  - `rbac.ensure_context_initialized()` raises **"User not found"** unless the user row exists → first login must call `public.get_userinfo()` to provision the user (which also auto-assigns the `User` role via trigger — see §5).
  - `_settings.jwt_aud` enforces the `aud` claim **only if seeded** — it is **not** seeded by default in pgdocker, so the DB does not enforce `aud` out of the box (`apps/test/tests/0250_test_jwt_aud.sql`). pg_hba sets `scope="openid"`.
- **pgdocker OAuth config** (`pgdocker/conf/pg_hba.conf`): issuer pinned to `https://oidc-test.semanti.us`, validator `pg_oidc_validator`, ident map → role `authenticated`. The test issuer mints tokens carrying `role: "authenticated"`.

## Prerequisite
This sample depends on **`foundation-dual-auth-plan.md`** being signed off first — specifically the `session`-mode `semantius_authenticator` role + the `SET LOCAL ROLE authenticated` + claims contract (incl. the **mandatory session-adapter security requirements**) on the local pgdocker stack. Do not start until then.

## The core insight: one flag, two modes (`DB_AUTH_MODE = bearer | session`)

A single flag selects the connection strategy; the *host* (local pgdocker / Neon / Supabase) is just a connection string. The two modes:

| | `bearer` (PG18 OAUTHBEARER) | `session` (Neon / Supabase / local) |
|---|---|---|
| Who authenticates the DB connection | the **end-user's bearer token** (SASL OAUTHBEARER) | a shared **`semantius_authenticator` login role** (password) |
| Who **verifies** the JWT signature | the **database** (validator + JWKS + aud) | the **app** (jose + remote JWKS) |
| How the user identity reaches RLS | validator publishes `request.jwt.claims`; `system_user` pins `sub` | app runs `SET LOCAL ROLE authenticated` + `set_config('request.jwt.claims', <json>, true)` |
| Connection sharing | one connection **per user/token** (no cross-user pool) | normal pool shared across users (pooler-safe) |
| Driver | custom OAUTHBEARER transport (pg-proxy) | node-postgres `Pool` — supports `db.transaction()` |
| Backends | self-hosted PG18 / local pgdocker | Neon, Supabase, **and** local pgdocker (via the foundation's `semantius_authenticator` role) |

**Security consequence:** in `session` mode the app is the *sole* trust boundary. `rbac.uid()` does **not** verify token signatures for non-OAuth sessions — it trusts whatever `request.jwt.claims` you inject (there is no `system_user` anti-spoof). So in `session` mode the app **must** cryptographically verify the JWT (signature, `iss`, `exp`, `aud`) against the issuer's JWKS before injecting. Required, not optional.

## Architecture

### 1. OAuth client (vendor-agnostic, no secret)
- Use **`oauth4webapi`** (standards-based, lightweight, no vendor lock-in) for authorization-code + **PKCE**.
- **Assumed IdP facts — live-probed during review, but NOT pinned anywhere in the repo, so treat as assumptions to confirm with a milestone-0 spike** (one real `authorize → callback → token` round-trip against `oidc-test.semanti.us`):
  - Client ID = **`public-client`** (the no-secret public client). **NOT** `test-client` — that one is confidential and `/token` rejects it without a secret (`invalid_client`). Every artifact in the repo uses `test-client` via the headless `/getaccesstoken` mint, *not* a browser flow — so this is the one path the repo actually exercises and it is the **dev/headless fallback**.
  - Redirect URI must be **allow-listed by the issuer**: probed allow-list contains `http://localhost:3000/oauth2_callback` and `/auth/oauth2_callback`. Arbitrary paths (`/api/auth/callback`) are rejected with `Invalid redirect_uri`.
  - The discovery doc **omits `code_challenge_methods_supported`**, so `oauth4webapi` will not auto-apply PKCE — the sample must **force S256** explicitly (the endpoint accepts S256; it's just not advertised). The issuer is HTTPS.
  - **Fallback:** if the live browser flow can't be confirmed, fall back to the `/getaccesstoken?user_id=..&client_id=test-client` mint for dev — it returns no refresh token, so the 401→refresh path stays unproven (see Open Questions).
- Routes (Node runtime):
  - `GET /api/auth/login` → generate PKCE verifier + `state` + `nonce`, stash in short-lived **`httpOnly; Secure; SameSite=Lax; Path=/`** cookies (Lax so they survive the IdP redirect back), redirect to issuer `authorization_endpoint`.
  - `GET /oauth2_callback` → validate `state` (CSRF) **and** verify `nonce` against the returned ID token (replay), exchange `code` (with PKCE verifier, **no secret**) at `token_endpoint`, store `access_token` (+ `refresh_token`) in **httpOnly, Secure, SameSite=Lax** cookies. Use oauth4webapi's `validateAuthResponse` + `processAuthorizationCodeResponse` (with `expectedNonce`). Never log tokens or put them in URLs.
  - `POST /api/auth/logout` → clear cookies.
- Discovery via `/.well-known/openid-configuration` of the chosen issuer.
- **Issuer is config**, but must be consistent with the backend (see Open Questions): the default sample issuer is `https://oidc-test.semanti.us` because that is what the PG18 validator trusts and it supports a browser auth-code flow.
- Access tokens are ~1h (`exp-iat=3600`); implement a **401 → refresh-token** path (the issuer advertises the `refresh_token` grant). Without it the demo breaks after an hour.
- After first successful login, call `public.get_userinfo()` once (on the **write** session — it INSERTs) to provision the `users` row.

### 2. Request-scoped session store
- `lib/db/session.ts`: an `AsyncLocalStorage<Session>` holding the active **transaction-bound Drizzle instance** for the current request.
- `withSession(token, fn)`:
  1. resolve the active **adapter** (from env),
  2. open/checkout a connection + `BEGIN`,
  3. `session` mode: `SET LOCAL ROLE authenticated` + inject the verified claims (before any rbac call, since `rbac.uid()` is cached per tx); `bearer` mode: rely on the DB validator,
  4. run `fn` with the tx Drizzle instance placed in ALS,
  5. `COMMIT` on success / `ROLLBACK` on throw, then release.
- `getDb()` returns the ambient session handle from ALS (throws if called outside a session) → the data-access layer never threads the connection manually. **Caveat:** the `bearer` adapter yields a `pg-proxy` Drizzle db and the `session` adapter yields a `node-postgres` *transaction* object — different types. `getDb()` must expose a **narrow common query interface** (the shared `select/insert/update/delete` + `execute` surface), not "the tx instance," so DAL code stays adapter-agnostic.
- Applied at **entry points**: route handlers + server actions wrap their body in `withSession`. For RSC, **use ONE request-scoped read session** — memoize it with React `cache()` (or the ALS store) so the connection + the per-request permission resolution happen **once per render**, shared across all server components, rather than a fresh session per `query()` call (N components → N transactions → N permission-CTE runs → N round-trips is a real fan-out cliff — see Scalability). The session opens lazily on first read and is finalized at the end of the request; don't hold one long write-tx across the whole tree.

### 3. Vendor-agnostic adapter (sets all claims)
**Self-contained:** the db layer (schema + adapters + transport + jose verify) is **vendored into `examples/nextjs/lib/db/`** — not a shared package — so the folder is copy-paste portable (matches the repo's existing example convention). The Hono sample vendors the *same* code; the design below is identical across both, kept in sync by hand + `drizzlegen`.
```
interface DbAdapter {
  // open connection, BEGIN, (session) SET LOCAL ROLE authenticated + inject claims / (bearer) plain, run fn, COMMIT/ROLLBACK, release
  runInSession(ctx: { token: string; claims: VerifiedClaims }, fn: (db: DbHandle) => Promise<T>): Promise<T>
}
// withSession(token, fn) = the ALS wrapper that calls the active adapter's runInSession and stores
// the handle so getDb() works anywhere. (Hono's middleware is the same wrapper wired into a request.)
// DbHandle = the narrow common query surface (select/insert/update/delete + execute), since the bearer
// adapter yields a pg-proxy db and the session adapter yields a node-postgres tx (different types).
```
Two adapters, selected by `DB_AUTH_MODE`:
- **`bearer`** (`DB_AUTH_MODE=bearer`): opens an OAUTHBEARER connection (vendored `pg-oauthbearer.ts`) with the user's token; Drizzle via `pg-proxy`. **No claim injection** (validator does it). Wraps `fn` in a transaction via manual `BEGIN`/`COMMIT` serialized over the transport (pg-proxy has no `db.transaction()`), with `ROLLBACK` on error — for uniformity + pooler-safety, not strictly required for single-statement correctness. Always `.end()` the connection in `finally` (no pool → socket leak). Verifies token client-side only for routing/identity, not as the DB trust boundary.
- **`session`** (`DB_AUTH_MODE=session`; Neon + Supabase + local pgdocker): node-postgres `Pool` connecting as the `semantius_authenticator` login role; `db.transaction(tx => { SET LOCAL ROLE authenticated; set_config('request.jwt.claims', verifiedPayload, true); await fn(tx) })`. **Must follow the foundation's MANDATORY session-adapter security requirements**: verify the JWT (jose) with **pinned `algorithms:['RS256']`** + `issuer` + `audience`, and **fail closed** on any verify/JWKS failure (never inject from an unverified token, no stale-keyset fallback); inject the **exact verified payload** (not a re-decode/merge), with `role` pinned server-side; only inside a tx (throw otherwise); refuse a superuser/owner connection at startup. Inject **before** the first rbac call (`rbac.uid()` is STABLE/cached per tx). The connection-string role must be granted `authenticated` (locally that's `semantius_authenticator`).
  - **Supabase transaction pooler (port 6543, Supavisor):** node-postgres uses **unnamed** extended-protocol statements by default, so it is transaction-pooler-safe **without any flag** — do **not** pass `name:` on queries or use Drizzle `.prepare()` (those create persistent named statements that break under transaction pooling). Note: `prepare: false` is a **postgres.js** option, *not* node-postgres — it does nothing here. Append `?sslmode=require`. The tx-always wrapping is required for `SET LOCAL` anyway.
  - **Neon:** standard `pg` over the pooled endpoint with `sslmode=require` works; Neon WS pool is the edge alternative.
  - **Local pgdocker:** connect as `semantius_authenticator` (no `sslmode` on localhost) — same code path as Neon/Supabase.
  - Confirmed: injecting a single `request.jwt.claims` JSON blob covers Neon, Supabase, and local — `rbac.uid()` normalizes the blob, so there is no per-backend claim-shape difference.
- What's injected into the DB is the **verified jose payload** (with `role:'authenticated'` pinned server-side); a UI-facing view may be *derived* from it, but never inject a separately-decoded or client-merged object.

### 4. Drizzle wiring
- **Vendor** the generated schema into `examples/nextjs/lib/db/schema/` (`deno task drizzlegen --output examples/nextjs/lib/db/schema`). Re-run drizzlegen to refresh; the folder stays self-contained.
- `bearer` path: pg-proxy + transport; transaction via manual `BEGIN`/`COMMIT` over the transport (see §3).
- `session` path: `drizzle-orm/node-postgres` with a real `Pool` (gives `db.transaction()` needed for `SET LOCAL ROLE` + `set_config LOCAL`).

### 5. Sample feature — respects the real RLS/seed model
- **Provisioning is automatic** (verified): calling `public.get_userinfo()` on first login INSERTs the `users` row, which fires the `AFTER INSERT` trigger `rbac.auto_assign_user_role()` (`apps/_core/migrations/0050_rbac_rls.sql:271-307`). That trigger grants every new user the `User` role (`user:read` + `public:read`); the **first** user in an empty DB *also* gets `Administrator` (`user:manage`, `admin`) — seed at `0040_rbac_seed.sql:17-52`. **No explicit role-assignment step is needed.**
- Permission reality (drives the demo):
  - **Read** `/users`: works for **any** provisioned user (`User` role grants `user:read`). Demonstrates RLS returning rows.
  - **Write** to `users` needs `user:manage` → only an **admin** (the first user, or one an admin promotes). Note: `user_roles` writes are themselves admin-gated (`0050_rbac_rls.sql` `user_roles_insert_policy` requires `admin`), so a normal user cannot self-promote.
- Demo design: show the read for any user; for the write, either (a) use the first/admin user for a `user:manage` update, or (b) demo a self-scoped action that a plain `User` is allowed. State which in the README — don't imply a normal user can write to arbitrary `users` rows.
- This exercises the read-only RSC session vs. the write (server action) session split.

## Config / env
```
DB_AUTH_MODE=bearer | session            # selects the adapter (NOT the host)
OAUTH_ISSUER=https://oidc-test.semanti.us
OAUTH_CLIENT_ID=public-client            # public/no-secret client (NOT test-client)
OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback   # must be issuer-allow-listed
# bearer mode (token authenticates the connection):
PG_HOST / PG_PORT / PG_DATABASE
# session mode (connect as semantius_authenticator, app injects claims):
DATABASE_URL=postgresql://semantius_authenticator:<pw>@host:port/db   # pw from gitignored env, never committed; local: no sslmode; Supabase 6543 & Neon: ?sslmode=require (node-postgres needs no prepare flag — unnamed statements, pooler-safe)
OAUTH_JWKS_URI / OAUTH_EXPECTED_AUD   # app-side verification (aud is ["public-client","api://default"])
```
- `export const runtime = 'nodejs'` on all DB-touching routes (AsyncLocalStorage + TCP/WS drivers are not Edge-compatible).

## Decision: this sample is a server-rendered BFF (locked)
The Next.js sample follows App Router best practices — server-side OAuth flow, token in an httpOnly cookie, data access from RSC/server actions. The decoupled SPA-over-API shape is **a separate companion sample** (Hono + React SPA), not this one. Both **vendor the same** DB layer (schema + adapters + session — copied, not shared); only the presentation/auth-transport tier differs.

## Required token claims (README MUST document)
The DB enforces a claims contract independent of the provider. Any OIDC issuer (test server, Auth0, Clerk, Entra) works **only if the access token carries**:

| Claim | Requirement | Used for |
|---|---|---|
| `role` | **MUST equal `authenticated`** | `rbac.uid()` rejects anything else. Auth0/Clerk do **not** emit this by default — add it via a custom claim (Auth0 Action / Clerk JWT template). Confirmed feasible on Auth0. |
| `sub` | **Required**, stable & unique | becomes `users.external_id`; identity for RLS/RBAC |
| `iss` | must equal the configured issuer | verified app-side (`session` mode) / by the validator (`bearer` mode) |
| `aud` | DB enforces only if `_settings.jwt_aud` is seeded (**off by default**), BUT app-side `aud` verification is **MANDATORY** in `session` mode per the session-adapter contract — independent of the DB's optional check (else a same-issuer token for another client is accepted). | audience check in `rbac.uid()` (supports scalar or JSON array) |
| `exp` / `iat` | standard | expiry validation |
| `email` | recommended | populates the user row via `get_userinfo()` |
| `name`, `given_name`, `family_name` | optional | profile fields |

README must state: swapping providers = change `issuer` + `client_id` + JWKS, **and** ensure the provider mints `role=authenticated` (+ matching `aud`).

## Security notes (call out in README)
- **`session` mode connects as `semantius_authenticator`** — a `NOINHERIT NOSUPERUSER NOBYPASSRLS` gatekeeper (the exact analogue of Supabase's own `authenticator`): it has no privileges of its own and *enforces* RLS by `SET ROLE authenticated`; it does **not** bypass RLS. The migrations create it identically on local/Neon/Supabase; we set its password per-env.
- **The actual RLS-bypass trap is the owner string:** never run `session` mode as the `postgres`/project-owner connection string the platforms hand you — that one is effectively superuser and **silently bypasses RLS** (returns every row). Always connect as `semantius_authenticator`; assert `rolsuper`/`rolbypassrls` are both false (foundation guardrail).
- `session` mode: app MUST verify the JWT before injecting; a forged `request.jwt.claims` would otherwise be trusted (no DB-side anti-spoof).
- Tokens in httpOnly/Secure cookies; PKCE state/nonce validated; never expose tokens to client JS.
- `bearer` mode: the DB is authoritative for `sub` via `system_user`; client-spoofed claims are ignored.

## Scalability & production caveats (README must state)
Sample-acceptable on a single dev instance; honest caveats for production:
- **Serverless connection management (the big one).** A Vercel/serverless deploy gives each instance its own node-postgres `Pool` → connection storms / exhaustion. Required guidance: keep `Pool.max` **small (often 1)** when sitting behind a transaction pooler (Supabase 6543 / Neon pooler), set a short `idleTimeoutMillis`, and prefer the **Neon serverless driver** (`@neondatabase/serverless`, HTTP/WS) for serverless. Size the app pool ≤ the pooler's per-tenant budget. Without this, a naive deploy exhausts connections.
- **RSC fan-out** (see §2): use one request-scoped read session (React `cache()`/ALS), not per-component sessions — else N components = N× transactions + permission-CTE runs.
- **Per-request permission CTE** and **`bearer`-mode ceiling**: as in the foundation's "Scalability & production caveats" (bearer ≈ `max_connections` concurrent users, no pooling; the recursive permission CTE re-runs per request — production needs an app-side permission cache).
- **Refresh-token storms.** ~1h `exp` + many clients ⇒ synchronized expiry can stampede the IdP at the hour boundary; add jitter / refresh-ahead in production (the sample's 401→refresh is fine for a demo).

## Open questions / risks (reviewer-updated)
1. **Issuer consistency — now a hard constraint, not an open question.** PG18 validator is pinned to `oidc-test.semanti.us`. The other real no-secret PKCE issuer (`oauth-hono-mcp`) is **multi-tenant**: discovery only exists at `/:orgId/.well-known/openid-configuration`, tokens carry a UUID `sub`, `tid: orgId`, and `aud: tenant://<orgId>` — none of which the pinned PG18 validator accepts. **Decision:** standardize on `oidc-test.semanti.us` for all three backends; treat `oauth-hono-mcp` as out of scope for the PG18 path (it would require repointing + rebuilding `pg_hba.conf`). The browser auth-code+PKCE flow on `oidc-test.semanti.us` is **confirmed working** (with `client_id=public-client` + an allow-listed redirect URI), not just the `/getaccesstoken` mint shortcut.
2. **`bearer`-mode connection pooling.** Token-authenticated connections can't be shared across users; a real deployment needs a per-user connection cache or per-request connect (handshake cost). For the sample, per-request connect is acceptable — flag it.
3. **pg-proxy + transactions — resolved.** `db.transaction()` is unsupported on pg-proxy (confirmed: it throws), so the `bearer` path wraps each request in a manual `BEGIN`/`COMMIT` (+`ROLLBACK` on error) serialized over the transport. The `session` path uses real `db.transaction()` on node-postgres. Both wrap every request in a tx (uniform + pooler-safe).
4. **RSC transaction lifecycle — resolved.** One **request-scoped read session** memoized via React `cache()`/ALS (connection + permission resolution once per render), not per-`query()` sessions; finalize at request end. See §2 + Scalability.
5. **`aud` / `scope`.** App-side `aud` verification is **mandatory** in `session` mode (DB default is off, but the adapter must check it). Confirm a real IdP (Auth0 — verified) can emit `role: authenticated`.
6. **Refresh tokens.** Does the chosen flow issue refresh tokens, and do we implement silent refresh or just re-login on 401?

## Implementation milestones
0. **Shared OAuth spike** (the same one in the Hono plan — run once, gates *both* samples before their milestone 2): confirm the live `oidc-test.semanti.us` browser flow — `public-client`, redirect allow-list, PKCE/S256, **and that a usable refresh token is issued** (1h `exp` breaks the demo otherwise). Fallback: the `test-client` `/getaccesstoken` mint.
1. Scaffold a **self-contained** Next.js app (App Router, TS, Node runtime) under `examples/nextjs/` with its own `package.json` (own deps: `drizzle-orm`, `pg`, `jose`, `oauth4webapi`, …). Vendor the db layer into `examples/nextjs/lib/db/` (schema + adapters + transport + jose verify) — copy-paste portable, no workspace wiring. Generate schema via `deno task drizzlegen --output examples/nextjs/lib/db/schema`. Note the latent drizzlegen FK-type bug (`fields.tableName`/`queue_table_events.tableName` typed `integer` but reference a `text` PK) — avoid those tables in the demo, and ideally fix it at the generator (`packages/cli/commands/drizzlegen.ts`).
2. OAuth client routes with `oauth4webapi` + **forced S256** PKCE; `client_id=public-client`, callback at `/oauth2_callback`.
3. `withSession` + ALS + `getDb()` (narrow common query interface). Always `.end()`/release the connection in a `finally` (the `bearer`-mode transport has no pool and will leak sockets otherwise).
4. `session` adapter (node-postgres Pool as `semantius_authenticator`; jose verify with pinned RS256 + issuer + **mandatory aud**, **fail-closed**; inject exact verified payload, `role` pinned; `SET LOCAL ROLE authenticated` + `set_config` LOCAL claims-first; **throw if not in a tx**; **refuse superuser/BYPASSRLS connection at startup**; no named/prepared statements) → test against local pgdocker, Neon, Supabase. Confirm `db.transaction()` pins one pooled client; add negatives (unreachable JWKS → 401; inject outside tx → throws).
5. `bearer` adapter (vendored transport; manual `BEGIN`/`COMMIT` per request, ROLLBACK-on-error + `.end()` in `finally`) → test against pgdocker (OAUTHBEARER).
6. First-login `get_userinfo()` provisioning **on the write path** (the `User` role is auto-assigned by trigger — no extra step).
7. `/users` read page (any user) + a permission-appropriate write (admin/first user for `user:manage`, or a self-scoped action) — not an unscoped write claimed to "just work" for normal users.
8. README: env presets per backend, **the required-claims table (incl. Auth0/Clerk `role` custom-claim note)**, the security/trust model, the provisioning+role requirement, and run instructions. **MUST include the per-backend trust model:** `bearer`/self-hosted verifies the JWT **in the DB** (`pg_oidc_validator`, RS256). **`session` mode is app-verify / one-gate on *every* backend — Supabase AND Neon** — because no off-the-shelf RS256 in-DB verifier exists (`pg_session_jwt` is EdDSA-only; Supabase can't install it anyway), so **no additional token validation can be added in the database** in `session` mode. The app's jose verification + the `semantius_authenticator` password are the protection; DB-enforced verification is `bearer`. State this in plain terms. **Also warn:** on a *fresh* DB the **first provisioned user becomes `Administrator`** (auto-assign trigger, `0050_rbac_rls.sql:271-307`) — do **not** point a shared/multi-user demo at the public token-minting issuer; use per-developer databases or seed an admin out-of-band.
9. Validate end-to-end against all three backends (this is where the Supabase-pooler and claim-injection round-trip get *proven*, not assumed).

## Companion sample (separate plan): Hono API + React SPA
The clean, decoupled counterpart — tracked separately. It is **independently self-contained** (vendors the *same* db layer; no shared package), so its folders copy-paste cleanly too. See notes below; not part of this sample's milestones.
- **React (Vite) SPA**: browser auth-code + PKCE (oauth4webapi or react-oauth2-code-pkce), access token in memory, `Authorization: Bearer` to the API.
- **Hono API** = resource server: a single middleware wraps each request (validate JWT in claims mode / pass token through in PG18 mode) → open connection + `BEGIN` → inject claims → put the tx Drizzle on the context → `next()` → commit/rollback/release. Hono makes the **lifecycle** trivial (one middleware = one clean begin/commit boundary), which is the part Next RSC makes awkward. But for **ambient cross-file access** (reusable logging / nested DAL calling `getDb()` without threading the context), it still needs AsyncLocalStorage — use Hono's `hono/context-storage` (`contextStorage()` + `getContext()`), which is ALS under the hood. So both samples share the same ALS-based `getDb()`; only the begin/commit placement differs.
- **PG18 OAuth is the natural showcase here**: the bearer token flows SPA → Hono → Postgres and the DB validates it (token-as-connection), no app-side verification required.
- Same Drizzle schema, same adapter interface, same DB claims contract → the two samples prove the data/auth layer is framework-agnostic.
