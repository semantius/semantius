# Next.js sample — vendor-agnostic OAuth → Drizzle under RLS

A Next.js (App Router) BFF that authenticates users with **OAuth (authorization-code
+ PKCE, no client secret)**, runs **every request inside a request-scoped
transaction** with the user's identity injected, and reads/writes through
**Drizzle** so the database's **RLS/RBAC** enforces per-user access.

The same code runs unchanged against three backends, selected by one env flag:

| `DB_AUTH_MODE` | Who authenticates the DB connection | Who verifies the JWT signature | Backends |
|---|---|---|---|
| `bearer` | the **end-user's token** (SASL OAUTHBEARER, PG18) | the **database** (`pg_oidc_validator`, RS256) | self-hosted PG18 / local pgdocker |
| `session` | a shared **`semantius_authenticator`** login role (password) | the **app** (jose + remote JWKS) | Neon, Supabase, **and** local pgdocker |

> `DB_AUTH_MODE` selects *how the connection authenticates*, **not** the host. The
> host is just a connection string.

This is the **server-rendered BFF** shape (token in an httpOnly cookie, data access
from RSC/server actions). The decoupled SPA-over-API counterpart is a separate
sample (Hono API + React SPA) that **vendors the same `lib/db/` layer**.

---

## Prerequisites

1. **Foundation signed off.** This sample consumes the dual-auth foundation
   (`plans/foundation-dual-auth-plan.md`): the `semantius_authenticator` role
   (`apps/_core/migrations/0011_session_authenticator.sql`), the local LOGIN/password
   (`pgdocker/init/11-session-role.sh`), and the pg_hba scram lines. See
   `pgdocker/README.md`.
2. **A migrated database** with the `_core` schema deployed (so `users`, the RBAC
   functions, and `public.get_userinfo()` exist).
3. **Node ≥ 20.** For `bearer` against local PG18 you also need the pgdocker stack up
   and able to reach the issuer's HTTPS JWKS endpoint outbound.

---

## Quick start

```bash
cd examples/nextjs
npm install
cp .env.example .env.local      # then edit .env.local (gitignored — never commit secrets)
npm run dev                     # http://localhost:3000
```

Open <http://localhost:3000>, click **Log in**, complete the OAuth flow, and you
land on `/users` (read under RLS) with a write demo.

---

## Environment presets

Copy `.env.example` → `.env.local` and use one block. **Never commit `.env.local`**
or a real `semantius_authenticator` password.

**`bearer` — local pgdocker (PostgreSQL 18 OAUTHBEARER)**
```env
DB_AUTH_MODE=bearer
OAUTH_ISSUER=https://oidc-test.semanti.us
OAUTH_CLIENT_ID=public-client
OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback
PG_HOST=localhost
PG_PORT=5432            # 5433 for the extension stack
PG_DATABASE=appdb
```

**`session` — local pgdocker (connect as `semantius_authenticator`)**
```env
DB_AUTH_MODE=session
OAUTH_ISSUER=https://oidc-test.semanti.us
OAUTH_CLIENT_ID=public-client
OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback
DATABASE_URL=postgresql://semantius_authenticator:devpassword@localhost:5432/appdb
OAUTH_JWKS_URI=https://oidc-test.semanti.us/jwks
OAUTH_EXPECTED_AUD=public-client
```

**`session` — Neon / Supabase**
```env
DB_AUTH_MODE=session
OAUTH_ISSUER=https://oidc-test.semanti.us
OAUTH_CLIENT_ID=public-client
OAUTH_REDIRECT_URI=http://localhost:3000/oauth2_callback
# Neon (pooled) and Supabase (port 6543, transaction pooler) both need sslmode=require.
# Connect as semantius_authenticator — NEVER the postgres/owner string (see Security).
DATABASE_URL=postgresql://semantius_authenticator:<pw>@<host>:<port>/<db>?sslmode=require
OAUTH_JWKS_URI=https://oidc-test.semanti.us/jwks
OAUTH_EXPECTED_AUD=public-client
```
> node-postgres is transaction-pooler-safe by default (it uses **unnamed**
> extended-protocol statements). Do **not** add a `name:` to queries or use Drizzle
> `.prepare()` — those create persistent named statements that break under
> transaction pooling. (`prepare: false` is a *postgres.js* option and does nothing
> with node-postgres.) On managed Postgres, first set the role's password over the
> owner connection: `deno task setup-session-role` (see `scripts/setup-session-role.ts`).

---

## Required token claims

The DB enforces a claims contract independent of the provider. Any OIDC issuer
(test server, Auth0, Clerk, Entra) works **only if the access token carries**:

| Claim | Requirement | Used for |
|---|---|---|
| `role` | **MUST equal `authenticated`** | `rbac.uid()` rejects anything else. Auth0/Clerk don't emit this by default — add a custom claim (Auth0 Action / Clerk JWT template). |
| `sub` | required, stable & unique | becomes `users.external_id`; identity for RLS/RBAC |
| `iss` | must equal the configured issuer | verified app-side (`session`) / by the validator (`bearer`) |
| `aud` | DB enforces only if `_settings.jwt_aud` is seeded (**off by default**); **app-side `aud` check is MANDATORY in `session` mode** | else a same-issuer token for another client is accepted |
| `exp` / `iat` | standard | expiry validation |
| `email` | recommended | populates the user row via `get_userinfo()` |
| `name`, `given_name`, `family_name` | optional | profile fields |

**Swapping providers** = change `OAUTH_ISSUER` + `OAUTH_CLIENT_ID` + `OAUTH_JWKS_URI`
(+ `OAUTH_EXPECTED_AUD`) **and** ensure the provider mints `role=authenticated`. The
test issuer's discovery omits `code_challenge_methods_supported`, so this client
**forces PKCE S256** explicitly (`lib/auth/oauth.ts`).

---

## Trust model (per backend) — read this

- **`bearer` (self-hosted PG18 / local):** the database verifies the JWT —
  `pg_oidc_validator` checks the RS256 signature against the issuer's JWKS, and
  PostgreSQL pins identity via `system_user` (`oauth:<sub>`), so a client cannot
  spoof `sub`. **DB-enforced verification.**
- **`session` (Supabase *and* Neon *and* self-hosted):** the **app is the sole
  trust boundary**. No off-the-shelf RS256 in-DB verifier exists (`pg_session_jwt`
  is EdDSA-only; Supabase can't install it anyway), so **no token validation can be
  added in the database** in this mode. The protection is the app's **jose
  verification** (`lib/db/verify.ts`: RS256 pinned, `iss`+`aud` mandatory,
  fail-closed) plus the **`semantius_authenticator` password**. If you inject a
  forged `request.jwt.claims`, the DB trusts it — so the app **must** verify first.

`semantius_authenticator` is a `NOSUPERUSER NOINHERIT NOBYPASSRLS` gatekeeper (the
analogue of Supabase's own `authenticator`): it has no privileges of its own and
*enforces* RLS by `SET ROLE authenticated`. The session adapter **refuses to start**
if its connection role is superuser/BYPASSRLS — the real RLS-bypass trap is
connecting as the `postgres`/project-owner string the platforms hand you (that one
silently returns every row). **Always connect as `semantius_authenticator`.**

---

## Provisioning & the first-user-is-Administrator warning

On first login the callback calls `public.get_userinfo()` once (an INSERT), which
fires the `AFTER INSERT` trigger that auto-assigns the **`User`** role
(`user:read` + `public:read`). **No explicit role step is needed.**

⚠️ On a **fresh** database the **first** provisioned user also gets **`Administrator`**
(`user:manage`, `admin`). So **do not point a shared/multi-user demo at the public
token-minting issuer** — anyone could mint a token and the first arrival would be an
admin. Use **per-developer databases** or seed an admin out-of-band.

What the demo shows:
- **Read `/users`** works for any provisioned user (`User` → `user:read`).
- **Write** (update display name) needs `user:manage` → only an admin (the first
  user). A plain `User` is correctly RLS-blocked (the action says so).

---

## Scalability & production caveats (honest)

Sample-acceptable on a single dev instance; for production:

- **Serverless connection management (the big one).** Each instance gets its own
  node-postgres `Pool` → connection storms behind a pooler. Keep `Pool.max` **small
  (often 1)** behind a transaction pooler (Supabase 6543 / Neon), set a short
  `idleTimeoutMillis`, and prefer the **Neon serverless driver** for serverless.
  This sample's `max` defaults to 10 (`PG_POOL_MAX` to override).
- **`bearer` does not scale past ~`max_connections` concurrent users** — one
  OAUTHBEARER connection per user/token, no pooling, ≥5 serialized round-trips per
  request. Demo / low-concurrency self-host only.
- **Per-request permission CTE.** `rbac.get_user_permissions()` runs once per
  transaction (cached in a LOCAL GUC that resets at COMMIT) → re-runs every request
  in both modes. Production needs an app-side permission cache.
- **RSC fan-out.** Use one request-scoped read session per render (this sample loads
  a page's data in a single `withSession`), not one session per component.
- **Refresh-token storms.** ~1h `exp` + many clients ⇒ synchronized expiry; add
  jitter / refresh-ahead in production. The sample's 401-avoidance refresh is fine
  for a demo.

---

## How it works (file map)

```
app/
  api/auth/login/route.ts      GET  -> PKCE verifier+state+nonce in cookie, redirect to issuer (S256 forced)
  oauth2_callback/route.ts     GET  -> validate state, verify nonce, exchange code (no secret), store tokens, provision
  api/auth/refresh/route.ts    GET  -> refresh tokens (for RSC, which can't write cookies), bounce back
  api/auth/logout/route.ts     POST -> clear cookies
  page.tsx                     home: shows mode + sign-in status
  users/page.tsx               RSC read under RLS (one request-scoped session)
  users/actions.ts             server action: the user:manage write demo (+ logout)
  users/update-name-form.tsx   client form (useActionState) for the write
lib/auth/
  oauth.ts        oauth4webapi client (discovery memoized, PKCE S256 forced, refresh)
  tokens.ts       httpOnly token + login-state cookies; proactive-expiry hint
  refresh.ts      ensureFreshToken() — refresh before use
  context.ts      resolve SessionContext; session mode verifies (cache()-memoized per render)
lib/db/           ← self-contained, copy-paste portable (the Hono sample vendors the SAME files)
  session.ts      AsyncLocalStorage + withSession() + getDb()
  adapter.ts      DbAdapter interface + SessionContext
  adapters/bearer.ts    OAUTHBEARER transport + pg-proxy; manual BEGIN/COMMIT; .end() in finally
  adapters/session.ts   node-postgres Pool as semantius_authenticator; db.transaction + SET LOCAL ROLE + inject; superuser guard
  verify.ts       jose RS256 verify (iss+aud mandatory, fail-closed); unsafe decode for bearer display
  types.ts        DbHandle (the narrow common Drizzle surface both adapters expose)
  pg-oauthbearer.ts / drizzle-proxy.ts   vendored transport + pg-proxy wiring
  schema/         vendored generated Drizzle schema
lib/dal/users.ts  data access over getDb() (provision, listUsers, updateDisplayName)
```

### Refreshing the vendored schema

The schema under `lib/db/schema/` is generated from the catalog. Refresh it with:

```bash
deno task drizzlegen --output examples/nextjs/lib/db/schema
```

> Known generator quirk: FK fields whose target PK is `text` (e.g. `fields.table_name`,
> `queue_table_events.table_name`) are emitted as `integer`. The demo only touches
> `users`/`roles`/`user_roles`/`permissions`, which are unaffected; avoid those two
> tables (or fix `packages/cli/commands/drizzlegen.ts`).

---

## Validation status

| Milestone | Status |
|---|---|
| 0 — OAuth spike (discovery: endpoints, **S256 omitted**, `refresh_token` grant advertised) | **confirmed**, incl. the live browser auth-code+PKCE round-trip against `oidc-test.semanti.us` with `client_id=public-client` + the allow-listed redirect. |
| 1–8 — app code (scaffold, adapters, session store, OAuth routes, demo, README) | **built** + `tsc`/`next build` green. |
| 2/5/6/7 — **full browser E2E against local pgdocker** | **PROVEN in a real browser** (Chrome via agent-browser): home → Log in → issuer Sign In (user1/password123) → `/oauth2_callback` (code exchange, PKCE, cookies) → `/users` renders the RLS read. **Both modes**: `bearer` (SASL OAUTHBEARER, incl. the `user:manage` write succeeding as the admin/first user) and `session` (SCRAM as `semantius_authenticator`, jose RS256/iss/aud verify on the real token, claim injection). |
| 5 — DB-layer headless checks | both adapters + the superuser-refusal guard pass on both local stacks (CLI 5432 + ext 5433). See `scripts/smoke-db.ts` / `scripts/smoke-guard.ts`. |
| 9 — Neon / Supabase | **pending** (credentials). |

Headless DB-layer checks (no browser; pgdocker stack must be up):
```bash
npx tsx scripts/smoke-db.ts bearer     # OAUTHBEARER path
npx tsx scripts/smoke-db.ts session    # SCRAM / app-verify path
npx tsx scripts/smoke-guard.ts         # superuser connection is refused
```

Full UI round-trip: `cp .env.example .env.local`, edit, `npm run dev`, then log in at
<http://localhost:3000> with a test user (e.g. `user1` / `password123`).
