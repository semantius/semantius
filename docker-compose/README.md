# docker-compose — PostgREST API stack for the Semantius extension DB

A **self-contained Docker Compose stack** that puts an HTTP API with browsable
OpenAPI docs, an admin SPA and an **OIDC identity provider** in front of a
PostgreSQL 18 database carrying the `pg_semantius` extension. Auth is part of the
stack rather than a prerequisite for it: the bundled `idp` service issues the
bearer tokens and publishes the keys PostgREST validates them against, so a fresh
`create` is a complete, self-hosted system with nothing to register anywhere.

Everything the database needs (extension install, roles, `pg_hba`, the
authenticator LOGIN, optional demo data) is **baked into the `semantius/postgres`
image** from [`../docker-postgres`](../docker-postgres/README.md), so the database
side mounts nothing from the host. The only host files the stack reads are the
sibling [`Caddyfile`](Caddyfile) and [`idp-config/`](idp-config/) — deliberately
plain, editable files. The deployment variant in
[`dokploy/`](#dokploy-one-click-template) embeds all of them, so a one-click
deploy really is just one compose file (see below).

A single **Caddy front door** on `WEB_PORT` fans out to the four HTTP services;
PostgREST, Scalar and the idp keep their own host ports for direct access in
local dev.

```
browser ──▶ Caddy (:7070) ──┬── /              ──▶ Admin SPA     (internal, no host port)
                            ├── /idp/*         ──▶ semantius-idp (also direct :3001)
                            ├── /.well-known/* ──▶ semantius-idp (issuer metadata, at the ORIGIN ROOT)
                            ├── /api-docs/*    ──▶ Scalar docs   (also direct :8080)
                            └── /api/*         ──▶ PostgREST     (also direct :3000, OpenAPI at /)
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET ROLE authenticated | anon  (per request)
                                                     ▼
                                       Postgres 18 + pg_semantius  (:5434)
                                                     ▲            ▲
                                                     │            │ schema `idp`: users, OAuth
                                                     │            │ clients, signing keys
your app ─▶ PgBouncer   (:6432) ──transaction pooling┤            │
            as semantius_authenticator (SET LOCAL ROLE)           │
            as postgres — the idp's runtime pool ─────────────────┘
```

## Quick start

```bash
cd docker-compose
cp .env.example .env   # Windows: copy .env.example .env  (create does this for you)
./create.sh            # pull the images + a FRESH database, stack up (Windows: create.cmd)
```

Then, **once**, create the first administrator: open
**http://localhost:7070/idp**. While the idp's user table is empty it serves a
first-run setup page, and whoever completes it becomes the first admin — there is
no bootstrap account and no password in the environment. Sign in to the admin SPA
at **http://localhost:7070/** with it.

- **Front door:** http://localhost:7070 — admin SPA at `/`, API at `/api/`,
  docs at `/api-docs/`, identity provider at `/idp/`.
- Direct, for local dev: **API** http://localhost:3000 · **Docs**
  http://localhost:8080 · **IdP** http://localhost:3001 (sign-in only works
  through the front door — see [below](#the-idp-service--the-bundled-identity-provider))

Then, day to day — every command is a script in **this folder**, `.sh` for bash and
`.cmd` for Windows ([full table below](#management-scripts)):

```bash
./up.sh                  # re-apply compose/.env/Caddyfile/idp-config changes  (KEEPS the data)
./create.sh --build      # same as create, but on an image built from your source
./status.sh              # what's running
./stop.sh  /  ./start.sh # stop / restart the containers (data kept)
./test.sh                # full pgTAP suite on a from-scratch stack  (DESTRUCTIVE)
./jwks-refresh.sh        # re-fetch the issuer keys after a rotation
./dokploy-build.sh       # regenerate the dokploy/ blueprint from this stack
./destroy.sh             # remove containers + volumes              (all data gone)
./token.sh user1         # OLD test issuer — see "Minting a token without a browser"
./api-test.sh            # ditto: it mints from the old test issuer
```

### `create` vs `up` — a fresh *container* is not a fresh *database*

The image's first-init scripts (`CREATE EXTENSION`, the authenticator LOGIN,
`anon`, the optional `NWIND` load) run **once per data directory**. Recreating
containers over an existing `pgdata` volume therefore keeps the **old** schema, no
matter how clean the containers are — which is why these are two commands rather
than one command with a flag:

| | wipes the DB? | use it when |
|---|---|---|
| **`create`** | **yes** — `down -v` first, so the image installs itself from scratch | you want a clean database: first run, after changing migrations or init scripts, or to test an image honestly. Prompts when a volume exists (`-y` skips) |
| **`up`** | no — containers only | you changed `docker-compose.yml`, `.env`, the `Caddyfile` or `idp-config/*.jsonc` and want it applied to the **running data** |

`create` is the exact inverse of `destroy`; `up` is `docker compose up
--force-recreate` with the image build in front of it. Reach for `up` when you
meant `create` and the symptom is a database that stubbornly reflects the previous
version — that is the init-once rule, not a broken image.

### Published image vs. local build

`create` and `up` **pull the DB image from GHCR**, like every other service in this
stack — so a fresh clone can stand the whole thing up with no Deno, no
`../extension` and no local build. A bare argument pins the tag:

```bash
./create.sh                  # fresh DB on the published image (tag from .env, default latest)
./create.sh 0.4.0-pg18       # ... pinned to a released tag
./up.sh     0.4.0-pg18       # swap the running stack onto that tag, keep the data
```

Pass **`--build`** to run YOUR working tree instead — `../docker-postgres/build.sh`
packages whatever is in `../extension` and tags it `:latest`. That is the
development loop, and it needs the extension generated first
(`deno task extension <version>` from the repo root):

```bash
./create.sh --build          # fresh DB on an image built from your source
./up.sh     --build          # rebuild + restart the containers, keep the data
```

A version tag names a *published* image, so `--build 0.4.0-pg18` is rejected rather
than silently running something else. And note that pulling `latest` **overwrites
the `:latest` tag a previous `--build` left behind** — run `--build` again to get
your source back.

> **`test` defaults the other way round**, deliberately: `create`/`up` are stack
> operations, so they run the registry image like every other service, while
> `test.sh` is a *source*-testing tool — it defaults to `--build` and takes
> `--pull` for the post-release check. Both flags work on all three.

## Services & images

Eight services (compose project `semantius`), seven long-running + one one-shot.
The **container** names say what each one is rather than repeating the service
name — `postgrest` runs as `semantius-api`, `scalar` as `semantius-docs`, `web`
as `semantius-app`, `jwks-fetch` as `semantius-jwks`; the rest match
(`semantius-postgres`, `-pgbouncer`, `-idp`, `-caddy`). Use the **service** name
with `docker compose`, the **container** name with plain `docker`:

| Service | Image | Host port | Purpose |
|---|---|---|---|
| `postgres` | `ghcr.io/semantius/postgres:${SEMANTIUS_DB_VERSION}` (built from [`../docker-postgres`](../docker-postgres/README.md)) | **5434** | PG18 with the extension installed + roles/pg_hba/authenticator/nwind baked in |
| `pgbouncer` | `edoburu/pgbouncer:latest` | **6432** | transaction-pooled `semantius_authenticator` endpoint for apps that talk SQL directly ([see below](#the-pgbouncer-service--a-pooled-endpoint-for-external-apps)) |
| `idp` | `ghcr.io/semantius/semantius-idp:${SEMANTIUS_IDP_VERSION}` | **3001** | **the bundled OIDC/OAuth issuer**, served at `/idp` — signs the bearer tokens and publishes the JWKS ([see below](#the-idp-service--the-bundled-identity-provider)). Shares `postgres` in its own `idp` schema; configured by [`idp-config/*.jsonc`](idp-config/) |
| `jwks-fetch` | `curlimages/curl:latest` | — | **one-shot**: downloads the issuer JWKS to a file PostgREST can read (see below) |
| `postgrest` | `postgrest/postgrest:latest` | **3000** | HTTP API; verifies the JWT vs the JWKS; serves OpenAPI at `/` |
| `scalar` | `scalarapi/api-reference:latest` | **8080** | renders PostgREST's Swagger 2.0 spec as browsable docs |
| `web` | `ghcr.io/semantius/semantius-app:${SEMANTIUS_APP_VERSION}` | — | static admin SPA (nginx). **SPA only** — it proxies nothing; reach it through `caddy`. Runtime config is written to `config.js` at container start from its `VITE_*` env |
| `caddy` | `caddy:2-alpine` | **7070** | **front door**: `/` → the SPA, `/api/*` → PostgREST, `/api-docs/*` → Scalar (both prefixes stripped), `/idp/*` and `/.well-known/*` → the idp (prefix **kept**). Routes live in the sibling [`Caddyfile`](Caddyfile) — edit it and `docker compose restart caddy` |

The registry images use `:latest` and `pull_policy: always` (re-pulled on every
`create`); `postgres` is the locally-built image, used as-is. Pin
`postgrest`/`scalar` to fixed tags once you're happy.

> **The SPA's control plane is opt-OUT.** The `web` service sets
> `VITE_CONTROL_PLANE_URL: " "` — a **single space**, and it is load-bearing.
> Unset *or empty* leaves the image's cloud default in place, which sends the app
> to `api.semantius.cloud` for a tenant lookup and fails to boot when self-hosted;
> a whitespace value survives the runtime-env filter and trims to `""` in the app,
> selecting self-hosted mode. Don't "tidy" it away — the comment in
> `docker-compose.yml` says the same thing next to the line.

## Environment variables (`.env`)

Every variable the **compose file** consumes. Copy `.env.example` → `.env` and
edit. `.env` is gitignored; `.env.example` is the committed template.

The `.env` groups these into a **change-first** block (your OIDC issuer) and a
**defaults** block; the table below follows that order.

| Var | Default | Used by | Purpose |
|---|---|---|---|
| `IDP_SECRET` | **(required)** — dev default in `.env.example` | `idp` | Signs the idp's sessions **and encrypts its JWT signing keys at rest**. ≥ 32 random bytes (`openssl rand -base64 48`). Change it for anything shared or exposed — and treat rotating it as a key rotation: it logs everyone out and makes the stored signing keys undecryptable. |
| `SEMANTIUS_IDP_VERSION` | `latest` | `idp` | Tag of the `semantius-idp` image. Re-pulled on every `create`; pin for reproducible/server deploys. |
| `IDP_BASE_URL` | `http://localhost:${WEB_PORT}/idp` | `idp`, `web` | The **issuer**: scheme + host + the `/idp` mount path, no trailing slash. Every absolute URL the idp emits derives from it, and it is the default `aud` of its tokens. ⚠️ **Set going live** (`https://yourdomain.com/idp`). |
| `PUBLIC_WEB_ORIGIN` | `http://localhost:${WEB_PORT}` | `idp` | Origin of the admin SPA, no path. [`idp-config/oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) builds the SPA's redirect URIs from it, **matched exactly**. ⚠️ **Set going live.** |
| `RESEND_API_KEY` | *(unset)* | `idp` | Optional. Without it the idp runs **degraded**: password reset, e-mail verification and all notifications are disabled and hidden. Fine locally (admins create users); set it for anything real. |
| `VITE_OAUTH_CONFIG` | the bundled idp's `/.well-known/openid-configuration`, at the front-door root | `web`, `jwks-fetch` | OIDC discovery URL. The admin SPA resolves its OAuth endpoints from it, **and** `jwks-fetch` derives the JWKS from its `jwks_uri` when `JWKS_URL` is empty. Change it only to **replace** the bundled issuer. |
| `VITE_OAUTH_CLIENT_ID` | `public-client` | `web` | Public OAuth client id. Matches the SPA registered in [`idp-config/oauth_clients.jsonc`](idp-config/oauth_clients.jsonc). |
| `VITE_OAUTH_AUDIENCE` | `${IDP_BASE_URL}` | `web` | The RFC 8707 `resource` the SPA asks its access tokens to be issued for — it becomes their `aud`. **Load-bearing:** the SPA always sends one (falling back to a built-in placeholder when empty) and an issuer that validates resources rejects an unknown one, showing a bare *Login Error* on `/oauth2_callback`. Change it only with an external issuer. |
| `JWKS_URL` | `http://idp:3000/idp/.well-known/jwks.json` | `jwks-fetch` | Keys PostgREST validates bearer tokens against. Defaults to the bundled idp **in-network** — explicit rather than derived, because the `jwks_uri` the idp advertises carries its *public* URL, which that container can't resolve. Set it **empty** (present in `.env`, no value) to derive from `VITE_OAUTH_CONFIG`'s discovery document instead — what an external issuer wants. The compose uses `${JWKS_URL-…}`, not `${JWKS_URL:-…}`, so an empty value stays empty. |
| `POSTGRES_PASSWORD` | **(required)** | `postgres` | `postgres` DBA login password. The stack refuses to start if unset. |
| `POSTGRES_DB` | `semantius` | `postgres`, `postgrest` | Database created on first init and served by the API. |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | `postgres`, `postgrest` | Password for `semantius_authenticator`, the role PostgREST logs in as. Consumed by the image's baked `20-authenticator-login.sh` **and** by `PGRST_DB_URI` — kept in sync automatically. Per-environment secret. |
| `SEMANTIUS_DB_VERSION` | `latest` | `postgres` | Tag of the `semantius/postgres` image to run. Pin (e.g. `0.3.0-pg18`) for reproducible/server deploys; `latest` tracks your local `docker-postgres/build.sh`. |
| `SEMANTIUS_APP_VERSION` | `latest` | `web` | Tag of the `semantius/semantius-app` admin SPA image. Re-pulled on every `create`; pin for reproducible/server deploys. |
| `NWIND` | *(unset)* | `postgres` | Set to **any** non-empty value (e.g. `TRUE`) to load the optional Northwind demo module on first init. Takes effect only on a **fresh** data volume (init runs once). |
| `POSTGRES_PORT` | `5434` | `postgres` | Host port for Postgres (5432/5433 belong to pgdocker's cli/ext stacks). |
| `PGBOUNCER_PORT` | `6432` | `pgbouncer` | Host port for the transaction-pooled PgBouncer endpoint. |
| `POSTGREST_PORT` | `3000` | `postgrest`, `scalar` | Host port for the PostgREST HTTP API (OpenAPI spec at `/`). |
| `IDP_PORT` | `3001` | `idp` | Host port for the identity provider (3000 is taken). For poking at the container only — the idp's own URLs all carry the front door's origin, so signing in must go through `/idp`. |
| `DOCS_PORT` | `8080` | `scalar` | Host port for the Scalar docs site. |
| `WEB_PORT` | `7070` | `caddy` | Host port of the **front door**: `/` the SPA, `/api/*` the API, `/api-docs/*` the docs. The SPA itself has no host port. |
| `SITE_ADDRESS` | `:80` | `caddy` | The address Caddy serves inside the container. `:80` is plain HTTP — right for local dev and behind anything that terminates TLS (Dokploy/Traefik). On a **bare VPS** set your bare domain for automatic HTTPS, then publish `80:80` + `443:443` on `caddy` instead of `WEB_PORT`. |
| `PUBLIC_API_URL` | `http://localhost:${WEB_PORT}/api` | `postgrest`, `scalar` | Browser-reachable base URL of the API. Used for BOTH the OpenAPI spec's advertised server and the docs' spec `url` — both resolved by the browser, so NEVER the in-network `postgrest` hostname. Defaults to this stack's own front door, whose `handle_path /api/*` strips the prefix. Going live, set the public front-door URL **including** `/api`. |

> **Going live?** With the bundled issuer, what a real deployment must set is
> **`IDP_BASE_URL`** and **`PUBLIC_WEB_ORIGIN`** (your public front door, with and
> without the `/idp` path), a real **`IDP_SECRET`**, and the passwords. The
> `VITE_OAUTH_*` trio and `JWKS_URL` all follow from those and can be left alone.
> To use **your own issuer** instead, set `VITE_OAUTH_CONFIG`,
> `VITE_OAUTH_CLIENT_ID` and `VITE_OAUTH_AUDIENCE` to its values and `JWKS_URL` to
> empty (so the keys are derived from its discovery document) — the `idp` service
> keeps running but nothing points at it.

**Not `.env`-driven — hardcoded in the compose:**

- `POSTGRES_USER` — always `postgres`.
- `IDP_CONFIG_DIR` (`/config`) and `IDP_SCHEMA_NAME` (`idp`) — pinned in the
  compose so a stray host value cannot redirect the container to another
  configuration or another schema.
- The **test-token** helpers (`token` / `api-test`) mint from a
  **hardcoded** issuer in `pgdocker/verify_oauth.ts`, not an env var. Since the
  stack now validates against the **bundled idp**, those tokens no longer verify
  — see [Minting a token without a browser](#minting-a-token-without-a-browser).

The `postgrest`, `web` and `caddy` services also set fixed operational env
(`PGRST_*`, `VITE_API_BASE_URL`, `VITE_CONTROL_PLANE_URL`, …) inline; those are
documented by comments in `docker-compose.yml` and rarely need changing.

## The `jwks-fetch` service — why it exists

PostgREST validates each request's OIDC bearer token by checking its RS256
signature against the issuer's **JWKS** (public signing keys). But PostgREST
**cannot fetch a JWKS from a URL** — its `jwt-secret` only accepts *inline JSON*
or a *file path* (`@/path`).

`jwks-fetch` bridges that gap: a tiny one-shot `curl` container that, at stack
startup, downloads the JWKS **once** into a shared volume file (`/jwks/jwks.json`)
which PostgREST then reads via `PGRST_JWT_SECRET=@/jwks/jwks.json`. It runs as root
so it can write the fresh named volume, writes the file world-readable (PostgREST
runs as a different user), and PostgREST `depends_on` it with
`service_completed_successfully`.

**Which URL it fetches:**
- If **`JWKS_URL` is set** → it fetches that directly. It **defaults** to the
  bundled idp reached in-network, `http://idp:3000/idp/.well-known/jwks.json`.
  That is explicit rather than derived on purpose: the `jwks_uri` the idp
  advertises in its discovery document is built from its *public* base URL
  (`localhost:7070`), an address this container cannot resolve.
- If **`JWKS_URL` is empty** → it fetches **`VITE_OAUTH_CONFIG`** (the OIDC discovery
  document) and extracts its `jwks_uri`. That is the **external-issuer** path:
  point `VITE_OAUTH_CONFIG` at your issuer and blank `JWKS_URL`, and the SPA and
  the server both flow from the one setting. "Blank" means *present and empty* in
  `.env` — the compose defaults it with `${JWKS_URL-…}` rather than
  `${JWKS_URL:-…}`, so an empty value is honoured instead of quietly taking the
  bundled default back.

It `depends_on` the `idp` being **healthy**, so the default fetch cannot race the
issuer's startup.

- **Fail-closed:** if the issuer or discovery document is unreachable at boot (or the
  discovery document has no `jwks_uri`), `jwks-fetch` exits non-zero and PostgREST
  won't start.
- **Key rotation:** the JWKS is fetched **once per start**. When the issuer
  rotates signing keys, refresh them on demand with **`./jwks-refresh.sh`**
  (Windows: `jwks-refresh.cmd`) — it re-fetches `JWKS_URL` and restarts
  PostgREST so it re-reads the file (a ~1s API blip; the DB stays up). A restart is
  required rather than a reload signal because the key comes from the
  `PGRST_JWT_SECRET` env var, and PostgREST does **not** re-read env-var config on a
  config reload (`SIGUSR2` / `NOTIFY pgrst 'reload config'`).

  Most IdPs rotate slowly and publish new keys ahead of use, so running this on
  demand is usually enough. **Depending on how often your IdP rotates keys, you may
  want to run it on a schedule** — e.g. a daily cron:
  ```cron
  0 3 * * *  cd /path/to/docker-compose && ./jwks-refresh.sh >> /var/log/jwks-refresh.log 2>&1
  ```

## Volumes

| Volume | Mounted by | Holds |
|---|---|---|
| `pgdata` | `postgres` | the database cluster (survives stop/start; removed by `destroy`) |
| `jwks` | `jwks-fetch` (rw), `postgrest` (ro) | the fetched `jwks.json` |
| `caddy_data` | `caddy` | ACME account + issued certificates (only used when `SITE_ADDRESS` is a real domain) |
| `caddy_config` | `caddy` | Caddy's autosaved config |

## Auth model (how a request flows)

End to end, with the bundled issuer:

```
SPA (/)  ──authorization_code + PKCE S256──▶  idp (/idp)
                                               │  signs an ES256 access token carrying
                                               │  "role": "authenticated"  (a static claim,
                                               │  jwt.claims in idp-config/config.jsonc)
         ◀───────── access token ──────────────┘
SPA  ──Authorization: Bearer <jwt>──▶  Caddy /api/*  ──▶  PostgREST
                                                            │ verifies ES256 vs /jwks/jwks.json
                                                            │ reads the .role claim
                                                            ▼  SET ROLE authenticated
```

That static `role` claim is the whole integration: without it PostgREST falls back
to `anon` and every data request is *permission denied*. An **external** issuer has
to be configured to emit the same claim.

The token's `aud` is the issuer URL (`jwt.audience`, defaulted from
`IDP_BASE_URL`). `PGRST_JWT_AUD` is deliberately left unset — `rbac.uid()` enforces
the audience **in the database**, and only when `_settings.jwt_aud` is seeded (off
by default). If you seed it, seed it with exactly the `IDP_BASE_URL` value.

PostgREST logs in as **`semantius_authenticator`** (SCRAM, `NOSUPERUSER
NOINHERIT`) and `SET ROLE`s per request:

- **Valid bearer token** → PostgREST validates the signature against `jwks.json`,
  reads the `role` claim (key `.role`) and does `SET ROLE authenticated`,
  publishing the payload to `request.jwt.claims`. `rbac.uid()` reads that, requires
  `role='authenticated'` + a non-empty `sub`, and RLS takes over.
- **No / invalid token** → `SET ROLE anon`. `anon` has schema `USAGE` only (no
  table grants), so any data request fails with *permission denied* before RLS is
  even consulted.

The roles (`authenticated`, `semantius_user`, `semantius_authenticator`) are
created by the extension itself; the `semantius/postgres` image's baked init scripts only
flip `semantius_authenticator` to LOGIN+password and add the `anon` role — this
stack mounts nothing.

### The OpenAPI docs are public, the data is not

`PGRST_OPENAPI_MODE=ignore-privileges` makes PostgREST emit the **full** spec for
the token-less docs request (so Scalar renders every endpoint) while `anon` still
can't read a single row. `PGRST_OPENAPI_SECURITY_ACTIVE=true` adds a JWT bearer
scheme so the docs show an **Authentication** panel — mint a token with
`./token.sh <user>` and paste `Bearer <token>`.

## The `pgbouncer` service — a pooled endpoint for external apps (and the idp)

PgBouncer pools **two logins**, both configured through the single
`DATABASE_URLS` variable (edoburu/pgbouncer's comma-separated multi-user form —
its entrypoint writes one `userlist.txt` entry per distinct user, so nothing has
to be mounted):

- **`semantius_authenticator`**, published on **`localhost:6432`** for apps that
  speak SQL to the database directly instead of going through PostgREST — the
  same role PostgREST uses, so the identical RBAC/RLS rules apply;
- **`postgres`**, the **idp's runtime pool** (its `DATABASE_URL`). Not published
  — it is reached in-network as `pgbouncer:5432`.

Two things that parser earns: every password spliced into `DATABASE_URLS` must be
**URL-safe** (no `@ : / ? #` or spaces), and `IGNORE_STARTUP_PARAMETERS` has to
list **`search_path`** alongside the image's default `extra_float_digits` —
PgBouncer *rejects* an unknown startup parameter with a fatal
`unsupported startup parameter`, and the idp's driver sends a `search_path` as a
best-effort convenience (every query it emits is schema-qualified, so ignoring it
changes nothing). Without that line every idp query through the pooler dies at
connect.

The published endpoint:

```
postgresql://semantius_authenticator:${SEMANTIUS_AUTHENTICATOR_PASSWORD}@localhost:${PGBOUNCER_PORT}/${POSTGRES_DB}
```

Transaction pooling returns the server connection to the pool at every `COMMIT`, so
the client **must** scope its identity to the transaction — the `SET LOCAL ROLE`
pattern documented in [`../pgdocker/README.md`](../pgdocker/README.md):

```sql
BEGIN;
SET LOCAL ROLE authenticated;                             -- transaction-scoped
SELECT set_config('request.jwt.claims', $1::text, true);  -- LOCAL; inject BEFORE any rbac call
-- … queries …
COMMIT;
```

Session-level `SET ROLE` / `set_config(…, false)`, `LISTEN`/`NOTIFY`, session
prepared statements and advisory locks do **not** survive transaction pooling —
never use them on this endpoint.

**What deliberately does *not* go through it:**

- **PostgREST** keeps its direct `postgres:5432` connection: it depends on
  `LISTEN`/`NOTIFY` (`PGRST_DB_CHANNEL_ENABLED=true`) to pick up the CLI's schema
  reloads, which transaction pooling breaks.
- **The CLI / `deno task migrate`** connects directly on **5434** — migrations run
  DDL and session-level state.
- **The idp's own migrations, CLI and cleanup job** use a second, direct URL
  (`DATABASE_URL_ADMIN` → `postgres:5432`): they hold *session* advisory locks,
  which a transaction pooler does not preserve. Only its ordinary runtime traffic
  goes through the pool.

## The `idp` service — the bundled identity provider

[semantius-idp](https://github.com/semantius/semantius-idp) is a full OIDC/OAuth
authorization server, and in this stack it is the **default issuer**. It shares
`postgres` (its own `idp` schema, migrated on boot), holds the users, the OAuth
clients and the signing keys, and needs no volume of its own.

### Mounted at `/idp`, discoverable at the origin root

Caddy proxies `/idp/*` **without stripping the prefix** (`handle`, not
`handle_path`). The prefix is part of the issuer: `server.baseUrl` carries it and
the idp renders every link, cookie `Path`, e-mail URL and redirect from that one
value. Strip it and sign-in *appears* to work while the session cookie is set on a
path the browser never sends back.

The metadata is the mirror-image problem. A client handed the issuer
`<origin>/idp` does **not** fetch `{issuer}/.well-known/...` — RFC 8414 §3.1 puts
the well-known segment *between* the host and the path. So the Caddyfile routes
all of these to the idp:

| Path | Why |
|---|---|
| `/.well-known/openid-configuration` | the root form, used by this stack's own SPA |
| `/.well-known/oauth-authorization-server` | ditto, RFC 8414 spelling |
| `/.well-known/jwks.json` | the signing keys |
| `/.well-known/oauth-authorization-server/idp` | the **RFC 8414 suffix form** a strict client asks for |
| `/.well-known/openid-configuration/idp` | the OIDC-discovery spelling of the same |

Those paths live at the origin root, which otherwise belongs to the SPA, so they
have to be routed explicitly. Nothing does it for you, and the symptom is a client
that cannot discover an idp which is working perfectly.

### Start ordering (why the healthchecks look paranoid)

The idp is the first service in this stack that connects to Postgres over TCP
**without a retry loop of its own**, and it exposed a race the others had been
papering over:

- `postgres`'s healthcheck is `pg_isready -h 127.0.0.1`. The `-h` is
  load-bearing — a bare `pg_isready` uses the unix socket, which starts answering
  during the image's **first-init** phase while the server still runs with
  `listen_addresses=''` and refuses every TCP client. On a fresh volume that gap
  is over a minute. `start_period` covers the init without counting failures.
- the idp's own healthcheck probes **`/idp/readyz`**, not `/idp/healthz`.
  `healthz` is liveness ("the process is up") and answers 200 while the database
  is still unreachable; `readyz` checks config, database, migrations *and* the
  signing key. `jwks-fetch` waits on the idp being healthy before downloading the
  keys, and it is a one-shot — if it fires too early it fails, and `create` fails
  with it.
- `jwks-fetch`'s curl adds `--retry-all-errors` so a 5xx from an
  almost-ready issuer is retried, not just a refused connection.

Both probe URLs carry the `/idp` prefix, because under a sub-path that is where
those endpoints live — a probe of the origin root would report a healthy container
as failing.

### Configuration

Two commented JSONC files in [`idp-config/`](idp-config/), bind-mounted
**read-only** — the container never writes its own configuration:

| File | Holds |
|---|---|
| [`config.jsonc`](idp-config/config.jsonc) | the issuer, the database (pooled + direct), the token shaping, sign-up policy, branding |
| [`oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) | the OAuth clients — the source of truth, reconciled into the database at every start |

They accept `${env:NAME}` / `${env:NAME:-default}` placeholders, resolved from the
`idp` service's environment. Configuration is read **once, at start-up**: edit,
then `docker compose restart idp`. There is no hot reload and `SIGHUP` is ignored.

Three settings there are load-bearing and worth knowing:

- **`database.ssl: "disable"`** — the idp defaults `ssl` to `require` for any
  non-localhost host, and the bundled Postgres speaks plain TCP inside the compose
  network. Without this it cannot connect at all.
- **`jwt.claims: { "role": "authenticated" }`** — the static claim PostgREST maps to
  a database role. A *static* claim, so it belongs here and not in a `roles.jsonc`
  (that file is the per-user catalog, emitted as the `roles` array).
- **`server.trustProxy: true`** — the idp always sits behind this stack's Caddy,
  which sets `X-Forwarded-*` by default.

`server.allowInsecureHttp` is *not* needed for `http://localhost:7070/idp` —
localhost is exempt from the https requirement. Turn it on only to reach a dev
stack over a LAN IP (`http://192.168.x.x:7070/idp`), never on a real deployment.

### Adding an OAuth client

Add an entry to [`oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) and
`docker compose restart idp`. At start-up the file is reconciled into the database
under an advisory lock: new clients are inserted, changed ones updated, and a
client **no longer listed is disabled** and its tokens revoked (deleted instead,
if you set `oauth.reconcile.prune`). Dynamic client registration is off and the
client CRUD endpoints are unreachable, so this file is the only way in.

Redirect URIs are **exact matches, no wildcards**. The shipped SPA entry builds
its one URI as `${PUBLIC_WEB_ORIGIN}/oauth2_callback`, which is what the admin app
actually requests (`${window.location.origin}/oauth2_callback`). A mismatch shows
up as an error page on the idp naming the offending URI.

### Minting a token without a browser

`./token.sh` and `./api-test.sh` mint from the **old public test issuer**
(hardcoded in `pgdocker/verify_oauth.ts`), so their tokens no longer verify
against the bundled idp's keys. For the bundled issuer, use a per-user **API key**
instead — the supported scripted-access path (there is no `client_credentials`
grant):

1. sign in and create a key at `/idp/account/api-keys`;
2. exchange it for a JWT:

```bash
JWT=$(curl -s -H "x-api-key: idp_…" http://localhost:7070/idp/api/auth/token \
      | sed 's/.*"token":"//; s/".*//')
curl -s -H "Authorization: Bearer $JWT" "http://localhost:7070/api/_settings?limit=1"
```

The exchanged token carries the same `"role": "authenticated"` claim, so PostgREST
treats it exactly like a browser token.

### Key rotation

The idp rotates its signing key every `jwt.rotationInterval` (90 days) and keeps
the retired one published for the grace period. PostgREST reads its keys from a
**file fetched once at startup**, so after a rotation run **`./jwks-refresh.sh`**
(see [above](#the-jwks-fetch-service--why-it-exists)) — or `idp rotate-keys`
followed by it, to rotate on demand:

```bash
docker compose exec idp idp rotate-keys
./jwks-refresh.sh
```

### Using a different issuer

The idp is the default, not a requirement. To point the stack at your own IdP,
set in `.env`:

- `VITE_OAUTH_CONFIG` — its discovery URL;
- `VITE_OAUTH_CLIENT_ID` — a public client registered there, whose redirect URI is
  `<your front door>/oauth2_callback`;
- `VITE_OAUTH_AUDIENCE` — the API audience it expects (its issuer URL, if it has
  no separate one);
- `JWKS_URL=` — **empty**, so `jwks-fetch` derives the keys from that discovery
  document.

Your issuer must mint `"role": "authenticated"` into its access tokens. The `idp`
service keeps running (nothing points at it); remove it from the compose file if
you want it gone.

## Management scripts

Thin wrappers over `docker compose` in this folder (project `semantius`);
each has a `.sh` (bash) and `.cmd` (Windows) form.

| Script | Does | `docker compose` |
|---|---|---|
| `create` | **from scratch**: wipe the volumes, pull the DB image, (re)create all containers and start them — a **fresh database** (copies `.env` on first run). Prompts when a volume exists; `-y` skips. A bare argument pins the tag; **`--build`** builds from [`../docker-postgres`](../docker-postgres/README.md) instead | `down -v` + `up -d --force-recreate --remove-orphans` |
| `up` | re-pull (or `--build`) the image and recreate the **containers**, **keeping the database** — for compose/`.env`/`Caddyfile`/`idp-config` changes. See [`create` vs `up`](#create-vs-up--a-fresh-container-is-not-a-fresh-database) | `up -d --force-recreate --remove-orphans` |
| `start` | start the existing (stopped) containers | `start` |
| `stop` | stop containers, keep them + volumes | `stop` |
| `status` | container status | `ps -a` |
| `destroy` | remove containers, network, and **both volumes** (keeps the image; confirm prompt). The inverse of `create` | `down -v` |
| `token` | mint a JWT for a test user from the **old public test issuer** — no longer valid against the bundled idp; see [Minting a token without a browser](#minting-a-token-without-a-browser) | — |
| `jwks-refresh` | re-fetch the issuer JWKS + restart PostgREST to pick up rotated keys (see [Key rotation](#the-jwks-fetch-service--why-it-exists)) | `run --rm jwks-fetch` + `restart postgrest` |
| `api-test` | mint a JWT → read data → confirm anon is blocked (HTTP/auth smoke test). Uses `token`, so the same test-issuer caveat applies | — |
| `test` | full pgTAP suite against a from-scratch stack (calls `create -y`, destructive). Defaults to **`--build`** (your source); **`--pull`** or a bare tag tests the published image | — |
| `dokploy-build` | regenerate the [`dokploy/`](#dokploy-one-click-template) blueprint from `docker-compose.yml` + `Caddyfile` + `idp-config/*.jsonc` (needs Node) | — |

> **Windows:** `start` and `test` are `cmd.exe` builtins, so invoke the scripts
> explicitly — `.\start.cmd`, `.	est.cmd` (bash: `./start.sh`, `./test.sh`).

## Dokploy one-click template

`docker-compose/dokploy/` is a **Dokploy blueprint** — the deployment variant of
this same stack, ready to drop into a Dokploy templates gallery.

```bash
./dokploy-build.sh     # from this folder (Windows: dokploy-build.cmd)
```

It is **generated** from `docker-compose.yml` + `Caddyfile` +
`idp-config/*.jsonc` by
[`../scripts/dokploy-build.mjs`](../scripts/dokploy-build.mjs) — which the script
above is a thin, folder-local wrapper around (it needs Node and the repo root's
`node_modules`) — and **committed**. Never hand-edit anything under `dokploy/` —
change the sources and regenerate. The transform:

- **strips every `ports:`** — a blueprint publishes nothing; Dokploy's Traefik
  routes to a service by name;
- **strips every `container_name:`** — fixed names collide across deployments;
- **embeds every bind-mounted file** — the `Caddyfile` and each
  `idp-config/*.jsonc` (discovered, not listed) — in a top-level `configs:` block
  with inline `content:`, so the blueprint needs no files beside it
  (`mounts = []` in `template.toml`). `$` is escaped as `$$` there so compose
  leaves Caddy's own `{$SITE_ADDRESS::80}` and the idp's `${env:…}` placeholders
  alone — each is resolved by its own reader;
- **drops `read_only:` from a service that gains such a config** — compose
  delivers an inline `content:` config by *writing it into* the container
  filesystem and refuses outright on a read-only one. That costs the `idp` its
  `read_only` in the blueprint and nothing else: `cap_drop`, `no-new-privileges`
  and the tmpfs survive;
- **validates the result** and fails loudly: no leftover ports, container names,
  custom networks or bind mounts; no read-only service carrying an inline config;
  every embedded file must round-trip back to its source and be mounted at the
  path its service expects; every `${VAR:?…}` the compose requires must be
  supplied by `template.toml`; the `[[config.domains]]` service must exist.

| File | What it is |
|---|---|
| `dokploy/docker-compose.yml` | the stack, portless, with the Caddyfile and the idp config embedded |
| `dokploy/template.toml` | Dokploy variables (`${domain}`, generated passwords, a generated `IDP_SECRET`), the env written to the deployment's `.env`, and the domain → `caddy`:80 mapping |
| `dokploy/meta.json` | gallery card: id, name, description, logo, links, tags |

The generated env wires the **bundled issuer** to the deployment's domain
(`IDP_BASE_URL=https://${main_domain}/idp`, `PUBLIC_WEB_ORIGIN=https://${main_domain}`,
a per-deployment `IDP_SECRET`), so a one-click deploy has a complete auth story:
visit `/idp` once and the first administrator is created. It also loads the
Northwind demo module (`NWIND=TRUE`) — drop that line for an empty database.

**Publishing it**, either way:

- fork [github.com/Dokploy/templates](https://github.com/Dokploy/templates) and
  copy the folder to `blueprints/semantius/` (add `logo.svg` — the build prints a
  reminder while `docker-compose/logo.svg` is missing), then point your instance
  at the fork as a custom templates repo;
- or, in any instance: **Create Service → Advanced → Import → Base64** of these
  files.

The target server needs **docker compose ≥ 2.23.1** (inline `configs.content`).

## Using the CLI against this stack

A repo-root [`.env.pgrest`](../.env.pgrest) profile points the Deno CLI at port 5434:

```bash
deno task connect --env pgrest                 # test the DBA connection
deno task migrate --apps test --env pgrest     # deploy more apps on top of _core
```

`_core` is already installed (by the extension), so `migrate` only deploys the
apps you name. After each migration the CLI fires `NOTIFY pgrst, 'reload schema'`,
which the running PostgREST picks up automatically (`PGRST_DB_CHANNEL_ENABLED=true`).

> ⚠️ **Change `IDP_SECRET`.** `.env.example` ships a dev default so the stack
> starts out of the box, exactly like `POSTGRES_PASSWORD`. It signs the identity
> provider's sessions and encrypts its signing keys — generate a real one
> (`openssl rand -base64 48`) before anything shared or network-exposed, and do it
> *before* first boot: rotating it later logs everyone out and makes the stored
> signing keys undecryptable.
