# Hono API sample — vendor-agnostic OAuth resource server → Drizzle under RLS

A standalone **Hono** HTTP API (Node runtime) that acts as a pure **OAuth resource
server**: it takes an `Authorization: Bearer <token>` from the React SPA, opens a
**request-scoped transaction**, injects the user's identity, and reads/writes
through **Drizzle** so the database's **RLS/RBAC** enforces per-user access.

This is the **decoupled** counterpart to [`examples/nextjs`](../nextjs) (the
server-rendered BFF). It **vendors the exact same `lib/db/` layer** — only the
auth-transport (bearer header, not cookies) and the presentation tier (a separate
[`examples/spa-frontend`](../spa-frontend) React SPA) differ. The data/auth layer
is proven framework-agnostic by running unchanged here.

The same code runs against three backends, selected by one env flag:

| `DB_AUTH_MODE` | Who authenticates the DB connection | Who verifies the JWT signature | Backends |
|---|---|---|---|
| `bearer` | the **end-user's token** (SASL OAUTHBEARER, PG18) | the **database** (`pg_oidc_validator`, RS256) | self-hosted PG18 / local pgdocker |
| `session` | a shared **`semantius_authenticator`** login role (password) | the **app** (jose + remote JWKS) | Neon, Supabase, **and** local pgdocker |

> `DB_AUTH_MODE` selects *how the connection authenticates*, **not** the host. The
> host is just a connection string.

---

## Architecture

The SPA holds the access token in memory and calls this API cross-origin. This API
is the resource server:

```
React SPA (:3000)  ──Authorization: Bearer──▶  Hono API (:8788)  ──▶  PostgreSQL (RLS/RBAC)
   (PKCE in browser,                              CORS → contextStorage →
    token in memory)                              session middleware (verify/forward
                                                  token + request-scoped tx) → Drizzle
```

**Middleware chain (order matters)** — see `src/server.ts`:
1. **CORS** (`hono/cors`): exact-match allowlist from `CORS_ORIGINS` (never `'*'`,
   never reflect an arbitrary Origin); allows the `Authorization` header and the
   write's `PUT`. The bearer model needs **no cookies** → `credentials:false` → no
   CSRF surface. Hono answers the `OPTIONS` preflight here, before auth (preflights
   carry no `Authorization`).
2. **`contextStorage()`**: AsyncLocalStorage for Hono's request context.
3. **session middleware** (`src/middleware/session.ts`, applied per data route):
   extract the bearer token → (session) **jose-verify, fail closed** / (bearer)
   decode for display → open **one request-scoped transaction** via the active
   adapter → run the handler under RLS → commit/rollback/release.

**Routes** (`src/routes/users.ts`):
- `GET /me` — first-call **provisioning** (`public.get_userinfo()`, a write path) +
  the current user. The SPA calls this once on load.
- `GET /users` — RLS-enforced list (any provisioned user has `user:read`).
- `PUT /me/display-name` — the **`user:manage` write demo** (admin/first user only).

---

## Quick start

```bash
cd examples/spa-hono-backend
npm install
cp .env.example .env       # edit .env (gitignored — never commit secrets)
npm run dev                # tsx watch, http://localhost:8788
```

Then start the SPA ([`examples/spa-frontend`](../spa-frontend)) on `:3000` and log
in there. To drive the API directly:

```bash
TOKEN=$(curl -s "https://oidc-test.semanti.us/getaccesstoken?user_id=user3&client_id=test-client")  # user3 = admin@test.com (the Administrator)
curl http://localhost:8788/me     -H "Authorization: Bearer $TOKEN"
curl http://localhost:8788/users  -H "Authorization: Bearer $TOKEN"
```

> Note: `/getaccesstoken` mints a **`test-client`** token (`aud=test-client`), which
> works in **bearer** mode. In **session** mode the app enforces
> `aud == OAUTH_EXPECTED_AUD`, so use a `public-client` token (i.e. log in via the
> SPA) or set `OAUTH_EXPECTED_AUD=test-client` for a direct curl.

---

## Environment

```env
DB_AUTH_MODE=bearer | session   # selects the adapter, NOT the host
PORT=8788                       # NOT 8787 (the oauth-hono-mcp sibling uses 8787)
CORS_ORIGINS=http://localhost:3000   # exact-match allowlist (comma-separated)

# session-mode JWT verification (REQUIRED in session mode; harmless in bearer)
OAUTH_ISSUER=https://oidc-test.semanti.us
OAUTH_JWKS_URI=https://oidc-test.semanti.us/jwks
OAUTH_EXPECTED_AUD=public-client

# bearer mode (the forwarded token authenticates the connection)
PG_HOST=localhost
PG_PORT=5432                    # 5433 for the extension stack
PG_DATABASE=appdb

# session mode (connect as semantius_authenticator; app injects verified claims)
#   local: no sslmode. Neon/Supabase 6543: ?sslmode=require.
#   node-postgres is transaction-pooler-safe by default (unnamed statements) — no prepare flag.
DATABASE_URL=postgresql://semantius_authenticator:<pw>@host:port/db
```

---

## Required token claims

The DB enforces a claims contract independent of the provider. Any OIDC issuer
works **only if the access token carries**:

| Claim | Requirement | Used for |
|---|---|---|
| `role` | **MUST equal `authenticated`** | `rbac.uid()` rejects anything else. Auth0/Clerk need a custom claim. |
| `sub` | required, stable & unique | becomes `users.external_id`; identity for RLS/RBAC |
| `iss` | must equal the configured issuer | verified app-side (`session`) / by the validator (`bearer`) |
| `aud` | DB enforces only if `_settings.jwt_aud` is seeded (**off by default**); **app-side `aud` check is MANDATORY in `session` mode** | else a same-issuer token for another client is accepted |
| `exp` / `iat` | standard | expiry validation (a cheap `exp` pre-check yields a uniform 401 in both modes → the SPA's 401→refresh works) |
| `email` | recommended | populates the user row via `get_userinfo()` |
| `name`, `given_name`, `family_name` | optional | profile fields |

---

## Trust model (per backend) — read this

- **`bearer` (self-hosted PG18 / local):** the **database** verifies the JWT —
  `pg_oidc_validator` checks the RS256 signature against the issuer's JWKS, and
  PostgreSQL pins identity via `system_user` (`oauth:<sub>`), so a client cannot
  spoof `sub`. The API need not verify the token itself. **DB-enforced verification.**
- **`session` (Supabase *and* Neon *and* self-hosted):** the **app is the sole trust
  boundary**. No off-the-shelf RS256 in-DB verifier exists (`pg_session_jwt` is
  EdDSA-only; Supabase can't install it anyway), so **no token validation can be
  added in the database** in this mode. The protection is the app's **jose
  verification** (`lib/db/verify.ts`: RS256 pinned, `iss`+`aud` mandatory,
  fail-closed) plus the **`semantius_authenticator` password**. If the app injected
  a forged `request.jwt.claims`, the DB would trust it — so the app **must** verify
  first, and `src/middleware/session.ts` does, before opening the transaction.

`semantius_authenticator` is a `NOSUPERUSER NOINHERIT NOBYPASSRLS` gatekeeper (the
analogue of Supabase's own `authenticator`): it has no privileges of its own and
*enforces* RLS by `SET LOCAL ROLE authenticated`. **The real RLS-bypass trap is the
owner string** — connecting as the `postgres`/project-owner string the platforms
hand you silently returns every row. The session adapter **refuses to start** if its
connection role is superuser/BYPASSRLS (verified at boot; `scripts/smoke-guard.ts`).
**Always connect as `semantius_authenticator`.**

The SPA persists tokens in `localStorage` (`react-oauth2-code-pkce`) so the session
survives a reload, with refresh-token rotation + a short access-token TTL bounding
the XSS-exfiltration window — see the SPA README's "Token storage & the security
tradeoff". CORS uses an origin allowlist; use HTTPS in prod. The bearer model has no
cookie CSRF, but tokens are XSS-exposed (the accepted tradeoff of a decoupled SPA).

---

## Provisioning & the first-user-is-Administrator warning

On first load the SPA calls `GET /me`, which runs `public.get_userinfo()` once (an
INSERT). That fires the `AFTER INSERT` trigger auto-assigning the **`User`** role
(`user:read` + `public:read`). **No explicit role step is needed.**

⚠️ On a **fresh** database the **first** provisioned user also gets **`Administrator`**
(`user:manage`, `admin`). So **do not point a shared/multi-user demo at the public
token-minting issuer** — anyone could mint a token and the first arrival would be an
admin. Use **per-developer databases** or seed an admin out-of-band.

What the demo shows:
- **`GET /users`** works for any provisioned user (`User` → `user:read`).
- **`PUT /me/display-name`** needs `user:manage` → only an admin (the first user). A
  plain `User` is correctly RLS-blocked → `{ ok:false, message:"Blocked by RLS…" }`.

---

## The vendored `lib/db/` layer (same as the Next sample)

`lib/db/` and `lib/dal/` are **copied byte-for-byte** from `examples/nextjs` (no
shared package — copy-paste portability is the accepted tradeoff; keep them in sync
by hand). The schema under `lib/db/schema/` is generated from the catalog:

```bash
deno task drizzlegen --output examples/spa-hono-backend/lib/db/schema
```

> Known generator quirk: FK fields whose target PK is `text` (e.g. `fields.table_name`,
> `queue_table_events.table_name`) are emitted as `integer`. The demo only touches
> `users`/`roles`/`user_roles`/`permissions`, which are unaffected; avoid those two tables.

```
src/
  server.ts              Hono app: CORS → contextStorage → routes; startup superuser guard
  middleware/session.ts  bearer-token extraction, jose verify (session), request-scoped tx
  routes/users.ts        GET /me (provision), GET /users (RLS read), PUT /me/display-name (write)
lib/db/                  ← vendored, identical to examples/nextjs/lib/db
  session.ts             AsyncLocalStorage + withSession() + getDb()
  adapter.ts             DbAdapter interface + SessionContext
  adapters/bearer.ts     OAUTHBEARER transport + pg-proxy; manual BEGIN/COMMIT; .end() in finally
  adapters/session.ts    node-postgres Pool as semantius_authenticator; tx + SET LOCAL ROLE + inject; superuser guard
  verify.ts              jose RS256 verify (iss+aud mandatory, fail-closed); unsafe decode for bearer display
  types.ts               DbHandle (the narrow common Drizzle surface both adapters expose)
  pg-oauthbearer.ts / drizzle-proxy.ts   vendored transport + pg-proxy wiring
  schema/                vendored generated Drizzle schema
lib/dal/users.ts         data access over getDb() (provision, listUsers, updateDisplayName)
scripts/                 headless DB-layer checks (smoke-db, smoke-guard)
```

---

## Runtime note

Node runtime is required: node-postgres and the OAUTHBEARER transport need raw TCP.
Cloudflare Workers can't do that without Hyperdrive/neon-http, and ALS on Workers
needs `nodejs_compat`. Bun/Deno are plausible but untested here.

---

## Scalability & production caveats (honest)

Sample-acceptable on a single dev instance; for production:

- **Pooler sizing.** `session` mode is transaction-pooler-safe (LOCAL `SET ROLE` /
  `set_config`). Keep `Pool.max` ≤ the pooler's per-tenant budget (`PG_POOL_MAX`,
  default 10), behind Supabase 6543 / Neon transaction pooler. If this API ever runs
  serverless, use a small `Pool.max` (often 1) + the Neon serverless driver; a
  long-running Node server can use a normal pool. Set a short `idleTimeoutMillis`.
- **`bearer` does not scale past ~`max_connections` concurrent users** — one
  OAUTHBEARER connection per user/token, no pooling (PgBouncer can't passthrough it),
  per-request connect + SASL. Demo / low-concurrency self-host only.
- **Per-request permission CTE.** `rbac.get_user_permissions()` runs once per
  transaction → re-runs every request in both modes. Production needs an app-side
  permission cache.
- **Refresh-token storms.** ~1h `exp` + many SPA clients ⇒ synchronized expiry can
  stampede the IdP at the hour boundary; add jitter / refresh-ahead in production.

---

## Validation status

| Milestone | Status |
|---|---|
| 0 — OAuth spike (public client, allow-listed redirect, **S256 forced**, refresh grant) | **confirmed** (shared with the Next sample; re-confirmed live via the SPA browser flow). |
| 1–7 — backend + SPA code (scaffold, adapters, middleware, routes, READMEs) | **built**, `tsc` green (backend), `tsc + vite build` green (SPA). |
| HTTP layer | `/me`, `/users`, `/me/display-name`, 401-on-no-token, and the CORS preflight verified via curl. |
| 9 — DB-layer headless checks | `smoke-db bearer` + `smoke-db session` + `smoke-guard` all pass on **both** local stacks (CLI 5432 + ext 5433). |
| 10 — **full browser E2E** | **PROVEN in a real browser** (Chrome via agent-browser), **both modes**: home(mode badge) → Log in → issuer Sign In (user1/password123) → `/oauth2_callback` (PKCE/S256 exchange via react-oauth2-code-pkce) → `/users` RLS read → `user:manage` write succeeds as user1 (admin/first user); a non-admin (user2) is correctly **RLS-blocked**; **reload (F5) keeps the session** (tokens in `localStorage`). CORS preflight + `Authorization` confirmed for the `:3000` origin. |
| 9 — Neon / Supabase | **pending** (credentials). |

Headless DB-layer checks (no browser; pgdocker stack must be up):
```bash
npm run smoke:bearer    # OAUTHBEARER path
npm run smoke:session   # SCRAM / app-verify path
npm run smoke:guard     # superuser connection is refused
# point at the extension stack:  PORT=5433 npm run smoke:bearer
```
