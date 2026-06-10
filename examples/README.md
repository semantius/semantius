# Examples

Runnable examples for integrating with a Semantic Platform database.

## Building blocks & query-layer examples

Low-level: connect with an OAuth token and run a query.

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`transport/`](transport/) | library | `@semantius/pg-oauthbearer` — a tiny, dependency-free Node client that authenticates to PostgreSQL 18 with an **OAuth bearer token** over SASL `OAUTHBEARER`. Also holds the shared `get-auth-token` helper. The shared building blocks. |
| [`kysely-raw/`](kysely-raw/) | example | List users with **Kysely** using **raw SQL** (no generated types) over an OAuth token. Vendors the building blocks above. |
| [`drizzle/`](drizzle/) | example | List users with **Drizzle**, **typed** via a schema generated from the catalog (`deno task drizzlegen`), over an OAuth token via `pg-proxy`. Includes Drizzle Studio. Vendors the building blocks above. |

Naming: a plain library name (`drizzle/`) is the **typed / schema-driven** flavor;
a `-raw` suffix (`kysely-raw/`) is **raw SQL with no generated types**.

## OAuth app samples (auth → request-scoped tx → Drizzle under RLS)

Full-stack samples that authenticate users with **OAuth (authorization-code + PKCE,
no secret)**, run **every request in a request-scoped transaction** with the user's
identity injected, and read/write through **Drizzle** so the database's **RLS/RBAC**
enforces per-user access. One env flag — **`DB_AUTH_MODE = bearer | session`** — runs
each unchanged against local PostgreSQL 18 OAUTHBEARER, Neon, and Supabase.

| Folder | Kind | What it is |
| ------ | ---- | ---------- |
| [`nextjs/`](nextjs/) | app sample | **Server-rendered BFF** (Next.js App Router). OAuth on the server, token in an **httpOnly cookie**, data access from RSC / server actions. |
| [`spa-hono-backend/`](spa-hono-backend/) | app sample | **Standalone Hono API** (Node) — a pure OAuth **resource server**: validates/forwards the bearer token, opens a request-scoped tx, injects claims, runs RLS-enforced Drizzle. Vendors the **same** `lib/db/` layer as `nextjs/`. |
| [`spa-frontend/`](spa-frontend/) | app sample | **Browser React SPA** (Vite). Runs the PKCE flow in the browser (`react-oauth2-code-pkce`, tokens in `localStorage`), **TanStack Router** with an auth-guarded route, and calls the Hono API with `Authorization: Bearer`. **No DB access.** |

`spa-frontend/` + `spa-hono-backend/` are **one decoupled sample** (SPA + API), the
counterpart to the `nextjs/` BFF. Both demonstrate the **same** `lib/db/` data/auth
layer — the SPA backend vendors it byte-for-byte from `nextjs/` — proving it's
framework-agnostic. See each folder's README for env presets, the required-claims
table, the per-backend trust model, and run instructions.

## Conventions

Each folder is a self-contained npm package — `cd` into it, run `npm install`, and
follow its README. Examples **vendor** copies of what they need so they run
standalone: the query-layer examples vendor the shared building blocks
(`pg-oauthbearer`, `get-auth-token`, canonical copies in [`transport/`](transport/));
the app samples vendor the generated Drizzle schema + adapters (`lib/db/`, refreshed
via `deno task drizzlegen --output <folder>/lib/db/schema`).
