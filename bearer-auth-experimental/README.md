# Bearer auth experiments (PostgreSQL 18 `OAUTHBEARER`)

**These are experiments, not deployment guidance. Bearer mode is not ready for
production for our use cases, and the reasons are not ours to fix.** Read
[docs/bearer-mode-status.md](../docs/bearer-mode-status.md) before building on
anything here.

Moved here from `examples/` on 2026-09-06, by decision, because leaving them
under a plain `examples/` implied they were the recommended starting point.

Bearer mode is the deployment where a client connects to PostgreSQL 18 directly
with an OAuth access token over SASL `OAUTHBEARER`, the database verifies the
token in-process through a validator module, and the session runs with the
identity pinned in `system_user` where no client can rewrite it. It is the
cleanest identity story this project can tell: no shared login role, no app tier
trusted to be honest about who is calling.

It is also the reason these samples are in a folder named "experimental".

## Why it is not ready

Two of the five blockers are structural and sit outside this repository:

1. **Neon and Supabase do not support bearer auth.** The `oauth` method in
   `pg_hba.conf` and the `oauth_validator_libraries` setting are server-side
   configuration neither platform exposes, and neither ships a validator. Bearer
   mode runs only where you control `postgresql.conf` and `pg_hba.conf` - that
   is, self-hosted PostgreSQL 18.
2. **No session pooler supports it.** PgBouncer, PgCat and Supavisor have no
   OAuth `auth_type` and no token passthrough. The obstacle is structural:
   `OAUTHBEARER` binds the identity to the server connection, so a
   transaction-mode pooler multiplexing users onto one backend cannot preserve
   it. Bearer mode therefore means one backend per user session, which rules it
   out for anything web-scale.

Three more are ours, and are tracked:

3. The validator is a third-party compiled module we build from source
   (Percona's `pg_oidc_validator`, plus a one-line patch that publishes the
   verified claims into `request.jwt.claims`).
4. The transaction-scoped permission cache is **bypassed** in bearer sessions,
   because `app.*` settings are client-writable when the client runs SQL
   directly. Every permission check costs about a millisecond instead of tens of
   microseconds, and per-row workloads pay that per row.
5. Only `sub` is trusted. The published `request.jwt.claims` is an ordinary
   user-settable GUC, so a bearer client can rewrite `email`, `name` and the
   rest. Everything that must be trusted derives from `system_user` and the
   `users` row.

The full account, including what "graduates" means and the tracking links, is in
[docs/bearer-mode-status.md](../docs/bearer-mode-status.md).

## What is in here

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`examples/transport/`](examples/transport/) | library | `@semantius/pg-oauthbearer` - a tiny, dependency-free Node client that authenticates to PostgreSQL 18 with an OAuth bearer token over SASL `OAUTHBEARER`. Also holds the shared `get-auth-token` helper. **The canonical copy**: the app samples under `examples/` vendor this file. |
| [`examples/kysely-raw/`](examples/kysely-raw/) | example | List users with **Kysely** using raw SQL (no generated types) over an OAuth token. |
| [`examples/kysely/`](examples/kysely/) | example | The same, **typed** from a schema generated off the catalog (`deno task kyselygen`). |
| [`examples/drizzle/`](examples/drizzle/) | example | List users with **Drizzle**, typed via a generated schema (`deno task drizzlegen`), over an OAuth token. Includes Drizzle Studio. |

Naming: a plain library name (`drizzle/`) is the typed, schema-driven flavor; a
`-raw` suffix (`kysely-raw/`) is raw SQL with no generated types.

### The full-stack app samples

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`examples/nextjs/`](examples/nextjs/) | app sample | **Server-rendered BFF** (Next.js App Router). OAuth on the server, token in an httpOnly cookie, data access from RSC and server actions. |
| [`examples/spa-hono-backend/`](examples/spa-hono-backend/) | app sample | **Standalone Hono API** (Node) as a pure OAuth resource server: validates and forwards the bearer token, opens a request-scoped transaction, injects claims, runs RLS-enforced Drizzle. Vendors the same `lib/db/` layer as `nextjs/`. |
| [`examples/spa-frontend/`](examples/spa-frontend/) | app sample | **Browser React SPA** (Vite). PKCE in the browser, TanStack Router with an auth-guarded route, calls the Hono API with `Authorization: Bearer`. **No DB access.** |

`spa-frontend/` + `spa-hono-backend/` are one decoupled sample (SPA + API), the
counterpart to the `nextjs/` BFF.

### What is not covered

**No sample puts PostgREST or the Supabase client in front of the database** -
including Neon's managed Data API, which is a PostgREST. The app-server half of
the portable path is covered by the two `session`-mode samples; the
API-in-front half is not. That gap is open.

## The session-mode caveat: for mature audiences

`nextjs/` and `spa-hono-backend/` are the two samples with a database tier, and
each takes one env flag, `DB_AUTH_MODE = bearer | session`. (`spa-frontend/` is a
browser SPA with no database access at all; it calls the Hono API.)

- **`bearer`** is the experiment above: self-hosted PostgreSQL 18 only.
- **`session`** authenticates with a shared `semantius_authenticator` login
  role, has the *app* verify the JWT against a remote JWKS, and injects the
  verified claims into a request-scoped transaction. It needs none of PostgreSQL
  18's OAuth machinery and is **built for Neon and Supabase** - pooler-safe
  unnamed statements, `sslmode=require`. It has **not been run against either**:
  both samples' own validation tables mark "Neon / Supabase" as *pending
  (credentials)* (`bearer-auth-experimental/examples/nextjs/README.md:236`,
  `bearer-auth-experimental/examples/spa-hono-backend/README.md:245`). Treat it as designed-for, not
  proven-on.

**You can build on `session` mode, but it is not the safe default the bearer
story was meant to be, and it is not a path for a team learning this codebase.**
The identity is only as good as the app tier's discipline, on every request,
forever:

- The connection is a **shared login role**. The database cannot tell one
  end-user from another; it believes the claims the app injected. Every guard in
  the schema is downstream of that one `set_config`.
- The claims must be injected **inside the same transaction** as the query, with
  `is_local = true`, on a **pinned** connection. A pooled client that returns the
  connection between the injection and the query, or that injects at session
  scope, leaks one user's identity into another user's request. The adapters in
  these samples get this right; a re-implementation is where it goes wrong.
- The app must verify the token itself - signature, issuer, audience, expiry -
  before injecting anything. Nothing downstream re-checks it.
- Any code path that reaches the database **outside** the adapter (a migration
  script, a background job, a hand-written query) has no identity at all, or
  worse, a stale one.

None of that is enforced by the database, and none of it fails loudly when it is
wrong: it fails as the wrong rows being returned to the wrong person. That is why
these samples sit here rather than being presented as the recommended starting
point. Treat them as a reference for people who already understand the trust
boundary, not as a template to copy.

## Running these

Each folder is a self-contained npm package - `cd` into it, `npm install`, and
follow its README. `kysely/` has none; it is the typed twin of `kysely-raw/`,
whose README applies to both.

`transport/` and the three query-layer examples, and the app samples under
`DB_AUTH_MODE=bearer`, need a PostgreSQL 18 server with the validator loaded;
[`../pgdocker/README.md`](../pgdocker/README.md) has the wiring, and
`pgdocker/pg-cli-start.sh` brings up an image that already has it. The app
samples under `DB_AUTH_MODE=session` need only a connection string, and run
against Neon, Supabase or the same local image - subject to the caveat above.

Examples **vendor** copies of what they need so they run standalone: the
query-layer ones vendor `pg-oauthbearer` and `get-auth-token` from
[`examples/transport/`](examples/transport/), the app samples vendor the
generated Drizzle schema and adapters (`lib/db/`, refreshed with
`deno task drizzlegen --output <folder>/lib/db/schema`).
