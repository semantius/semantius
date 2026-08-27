# docker-compose — PostgREST API stack for the Semantius extension DB

A **self-contained Docker Compose stack** that puts an HTTP API with browsable
OpenAPI docs and an admin SPA in front of a PostgreSQL 18 database carrying the
`pg_semantius` extension.

Everything the database needs (extension install, roles, `pg_hba`, the
authenticator LOGIN, optional demo data) is **baked into the `semantius/postgres`
image** from [`../docker-postgres`](../docker-postgres/README.md), so the database
side mounts nothing from the host. The only host file the stack reads is the
sibling [`Caddyfile`](Caddyfile) — deliberately a plain, editable file. The
deployment variant in [`dokploy/`](#dokploy-one-click-template) embeds it, so a
one-click deploy really is just one compose file (see below).

A single **Caddy front door** on `WEB_PORT` fans out to the three HTTP services;
PostgREST and Scalar keep their own host ports for direct access in local dev.

```
browser ──▶ Caddy (:7070) ──┬── /            ──▶ Admin SPA   (internal, no host port)
                            ├── /api/*       ──▶ PostgREST   (also direct :3000, OpenAPI at /)
                            └── /api-docs/*  ──▶ Scalar docs (also direct :8080)
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET ROLE authenticated | anon  (per request)
                                                     ▼
                                       Postgres 18 + pg_semantius  (:5434)
                                                     ▲
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET LOCAL ROLE authenticated  (per transaction)
your app ─▶ PgBouncer   (:6432) ──transaction pooling┘
```

## Quick start

```bash
cd docker-compose
cp .env.example .env   # Windows: copy .env.example .env  (create does this for you)
./create.sh            # pull the DB image + a FRESH database, stack up (Windows: create.cmd)
./api-test.sh          # smoke test: mint a JWT, read data, confirm anon is blocked
```

- **Front door:** http://localhost:7070 — admin SPA at `/`, API at `/api/`,
  docs at `/api-docs/`.
- Direct, for local dev: **API** http://localhost:3000 · **Docs** http://localhost:8080

Then, day to day — every command is a script in **this folder**, `.sh` for bash and
`.cmd` for Windows ([full table below](#management-scripts)):

```bash
./up.sh                  # re-apply compose/.env/Caddyfile changes  (KEEPS the data)
./create.sh --build      # same as create, but on an image built from your source
./status.sh              # what's running
./stop.sh  /  ./start.sh # stop / restart the containers (data kept)
./token.sh user1         # mint a test JWT to paste into the docs
./api-test.sh            # HTTP/auth smoke test against the running stack
./test.sh                # full pgTAP suite on a from-scratch stack  (DESTRUCTIVE)
./jwks-refresh.sh        # re-fetch the issuer keys after a rotation
./dokploy-build.sh       # regenerate the dokploy/ blueprint from this stack
./destroy.sh             # remove containers + volumes              (all data gone)
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
| **`up`** | no — containers only | you changed `docker-compose.yml`, `.env` or the `Caddyfile` and want it applied to the **running data** |

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

Seven services (project `semantius-rest`), six long-running + one one-shot:

| Service | Image | Host port | Purpose |
|---|---|---|---|
| `postgres` | `ghcr.io/semantius/postgres:${SEMANTIUS_DB_VERSION}` (built from [`../docker-postgres`](../docker-postgres/README.md)) | **5434** | PG18 with the extension installed + roles/pg_hba/authenticator/nwind baked in |
| `pgbouncer` | `edoburu/pgbouncer:latest` | **6432** | transaction-pooled `semantius_authenticator` endpoint for apps that talk SQL directly ([see below](#the-pgbouncer-service--a-pooled-endpoint-for-external-apps)) |
| `jwks-fetch` | `curlimages/curl:latest` | — | **one-shot**: downloads the issuer JWKS to a file PostgREST can read (see below) |
| `postgrest` | `postgrest/postgrest:latest` | **3000** | HTTP API; verifies the JWT vs the JWKS; serves OpenAPI at `/` |
| `scalar` | `scalarapi/api-reference:latest` | **8080** | renders PostgREST's Swagger 2.0 spec as browsable docs |
| `web` | `ghcr.io/semantius/semantius-app:${SEMANTIUS_APP_VERSION}` | — | static admin SPA (nginx). **SPA only** — it proxies nothing; reach it through `caddy`. Runtime config is written to `config.js` at container start from its `VITE_*` env |
| `caddy` | `caddy:2-alpine` | **7070** | **front door**: `/` → the SPA, `/api/*` → PostgREST, `/api-docs/*` → Scalar, both prefixes stripped. Routes live in the sibling [`Caddyfile`](Caddyfile) — edit it and `docker compose restart caddy` |

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
| `VITE_OAUTH_CONFIG` | test issuer's `/.well-known/openid-configuration` | `web`, `jwks-fetch` | ⚠️ **Change going live.** OIDC discovery URL. The admin SPA resolves its OAuth endpoints from it, **and** the server derives its JWKS from its `jwks_uri` when `JWKS_URL` is empty. |
| `VITE_OAUTH_CLIENT_ID` | `public-client` | `web` | ⚠️ **Change going live.** Public OAuth client id registered with your issuer. |
| `JWKS_URL` | *(empty → derived)* | `jwks-fetch` | Keys PostgREST validates bearer tokens against. **Optional** — leave empty to auto-derive from `VITE_OAUTH_CONFIG`'s discovery `jwks_uri`; set it only to override that (e.g. a keys endpoint not advertised in discovery). |
| `POSTGRES_PASSWORD` | **(required)** | `postgres` | `postgres` DBA login password. The stack refuses to start if unset. |
| `POSTGRES_DB` | `semantius` | `postgres`, `postgrest` | Database created on first init and served by the API. |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | `postgres`, `postgrest` | Password for `semantius_authenticator`, the role PostgREST logs in as. Consumed by the image's baked `20-authenticator-login.sh` **and** by `PGRST_DB_URI` — kept in sync automatically. Per-environment secret. |
| `SEMANTIUS_DB_VERSION` | `latest` | `postgres` | Tag of the `semantius/postgres` image to run. Pin (e.g. `0.3.0-pg18`) for reproducible/server deploys; `latest` tracks your local `docker-postgres/build.sh`. |
| `SEMANTIUS_APP_VERSION` | `latest` | `web` | Tag of the `semantius/semantius-app` admin SPA image. Re-pulled on every `create`; pin for reproducible/server deploys. |
| `NWIND` | *(unset)* | `postgres` | Set to **any** non-empty value (e.g. `TRUE`) to load the optional Northwind demo module on first init. Takes effect only on a **fresh** data volume (init runs once). |
| `POSTGRES_PORT` | `5434` | `postgres` | Host port for Postgres (5432/5433 belong to pgdocker's cli/ext stacks). |
| `PGBOUNCER_PORT` | `6432` | `pgbouncer` | Host port for the transaction-pooled PgBouncer endpoint. |
| `POSTGREST_PORT` | `3000` | `postgrest`, `scalar` | Host port for the PostgREST HTTP API (OpenAPI spec at `/`). |
| `DOCS_PORT` | `8080` | `scalar` | Host port for the Scalar docs site. |
| `WEB_PORT` | `7070` | `caddy` | Host port of the **front door**: `/` the SPA, `/api/*` the API, `/api-docs/*` the docs. The SPA itself has no host port. |
| `SITE_ADDRESS` | `:80` | `caddy` | The address Caddy serves inside the container. `:80` is plain HTTP — right for local dev and behind anything that terminates TLS (Dokploy/Traefik). On a **bare VPS** set your bare domain for automatic HTTPS, then publish `80:80` + `443:443` on `caddy` instead of `WEB_PORT`. |
| `PUBLIC_API_URL` | `http://localhost:${WEB_PORT}/api` | `postgrest`, `scalar` | Browser-reachable base URL of the API. Used for BOTH the OpenAPI spec's advertised server and the docs' spec `url` — both resolved by the browser, so NEVER the in-network `postgrest` hostname. Defaults to this stack's own front door, whose `handle_path /api/*` strips the prefix. Going live, set the public front-door URL **including** `/api`. |

> **Going live?** The only variables a real deployment is *required* to change are
> **`VITE_OAUTH_CONFIG`** and **`VITE_OAUTH_CLIENT_ID`** (your OIDC issuer's discovery
> URL + client id). `JWKS_URL` is derived from that discovery document automatically,
> so you normally leave it empty. Everything else has a working default — change the
> passwords too for anything shared or network-exposed.

**Not `.env`-driven — hardcoded in the compose:**

- `POSTGRES_USER` — always `postgres`.
- The **test-token** helpers (`token` / `api-test`) mint from a
  **hardcoded** issuer in `pgdocker/verify_oauth.ts`, not an env var — they're
  test-only, so there's no issuer knob here. The real issuer settings are the
  `VITE_OAUTH_*` pair and `JWKS_URL` above.

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
- If **`JWKS_URL` is set** → it fetches that directly.
- If **`JWKS_URL` is empty** → it fetches **`VITE_OAUTH_CONFIG`** (the OIDC discovery
  document) and extracts its `jwks_uri`. So pointing the whole stack at an issuer
  needs only `VITE_OAUTH_CONFIG` — the SPA and the server both flow from it.

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

## The `pgbouncer` service — a pooled endpoint for external apps

PgBouncer publishes a **transaction-pooled** endpoint on **`localhost:6432`** for
apps that speak SQL to the database directly instead of going through PostgREST.
It pools the `semantius_authenticator` login — the same role PostgREST uses — so
the identical RBAC/RLS rules apply:

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
- **The `postgres` DBA login** (the CLI, `deno task migrate`) connects directly on
  **5434** — migrations run DDL and session-level state.

## Management scripts

Thin wrappers over `docker compose` in this folder (project `semantius-rest`);
each has a `.sh` (bash) and `.cmd` (Windows) form.

| Script | Does | `docker compose` |
|---|---|---|
| `create` | **from scratch**: wipe the volumes, pull the DB image, (re)create all containers and start them — a **fresh database** (copies `.env` on first run). Prompts when a volume exists; `-y` skips. A bare argument pins the tag; **`--build`** builds from [`../docker-postgres`](../docker-postgres/README.md) instead | `down -v` + `up -d --force-recreate --remove-orphans` |
| `up` | re-pull (or `--build`) the image and recreate the **containers**, **keeping the database** — for compose/`.env`/`Caddyfile` changes. See [`create` vs `up`](#create-vs-up--a-fresh-container-is-not-a-fresh-database) | `up -d --force-recreate --remove-orphans` |
| `start` | start the existing (stopped) containers | `start` |
| `stop` | stop containers, keep them + volumes | `stop` |
| `status` | container status | `ps -a` |
| `destroy` | remove containers, network, and **both volumes** (keeps the image; confirm prompt). The inverse of `create` | `down -v` |
| `token` | mint a JWT for a test user (paste into the docs / use with curl) | — |
| `jwks-refresh` | re-fetch the issuer JWKS + restart PostgREST to pick up rotated keys (see [Key rotation](#the-jwks-fetch-service--why-it-exists)) | `run --rm jwks-fetch` + `restart postgrest` |
| `api-test` | mint a JWT → read data → confirm anon is blocked (HTTP/auth smoke test) | — |
| `test` | full pgTAP suite against a from-scratch stack (calls `create -y`, destructive). Defaults to **`--build`** (your source); **`--pull`** or a bare tag tests the published image | — |
| `dokploy-build` | regenerate the [`dokploy/`](#dokploy-one-click-template) blueprint from `docker-compose.yml` + `Caddyfile` (needs Node) | — |

> **Windows:** `start` and `test` are `cmd.exe` builtins, so invoke the scripts
> explicitly — `.\start.cmd`, `.	est.cmd` (bash: `./start.sh`, `./test.sh`).

## Dokploy one-click template

`docker-compose/dokploy/` is a **Dokploy blueprint** — the deployment variant of
this same stack, ready to drop into a Dokploy templates gallery.

```bash
./dokploy-build.sh     # from this folder (Windows: dokploy-build.cmd)
```

It is **generated** from `docker-compose.yml` + `Caddyfile` by
[`../scripts/dokploy-build.mjs`](../scripts/dokploy-build.mjs) — which the script
above is a thin, folder-local wrapper around (it needs Node and the repo root's
`node_modules`) — and **committed**. Never hand-edit anything under `dokploy/` —
change the two sources and regenerate. The transform:

- **strips every `ports:`** — a blueprint publishes nothing; Dokploy's Traefik
  routes to a service by name;
- **strips every `container_name:`** — fixed names collide across deployments;
- **embeds the `Caddyfile`** in a top-level `configs:` block with inline
  `content:` instead of the bind mount, so the blueprint needs no files beside it
  (`mounts = []` in `template.toml`). `$` is escaped as `$$` there so compose
  leaves Caddy's own `{$SITE_ADDRESS::80}` placeholder alone;
- **validates the result** and fails loudly: no leftover ports, container names,
  custom networks or bind mounts; the embedded Caddyfile must round-trip back to
  the source; every `${VAR:?…}` the compose requires must be supplied by
  `template.toml`; the `[[config.domains]]` service must exist.

| File | What it is |
|---|---|
| `dokploy/docker-compose.yml` | the stack, portless, with the Caddyfile embedded |
| `dokploy/template.toml` | Dokploy variables (`${domain}`, generated 32-char passwords), the env written to the deployment's `.env`, and the domain → `caddy`:80 mapping |
| `dokploy/meta.json` | gallery card: id, name, description, logo, links, tags |

The generated env keeps the **test issuer** defaults so a one-click deploy works
immediately, and loads the Northwind demo module (`NWIND=TRUE`). Both are meant to
be changed: point `VITE_OAUTH_CONFIG` / `VITE_OAUTH_CLIENT_ID` at your own IdP,
and drop `NWIND` for an empty database.

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

> ⚠️ **Test issuer only.** `https://oidc-test.semanti.us` is a public, throwaway
> OIDC server that mints tokens for anyone. Point `JWKS_URL` and the `web` service's
> `VITE_OAUTH_*` at your own trusted issuer before deploying anything real.
