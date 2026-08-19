# pgrest — PostgREST API stack for the Semantius extension DB

A **self-contained Docker Compose stack** that puts an HTTP API with browsable
OpenAPI docs and an admin SPA in front of a PostgreSQL 18 database carrying the
`pg_semantic_platform` extension.

Everything the database needs (extension install, roles, `pg_hba`, the
authenticator LOGIN, optional demo data) is **baked into the `semantius-db`
image** from [`../docker-semantius`](../docker-semantius/README.md), so this stack
mounts nothing from the host — it is just this `docker-compose.yml` + a `.env`.
That makes it a copy-paste Dokploy template.

```
browser ──▶ Admin SPA   (:7070) ──/api/*──▶ PostgREST
browser ──▶ Scalar docs (:8080) ──fetch spec──▶ PostgREST (:3000, OpenAPI at /)
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET ROLE authenticated | anon  (per request)
                                                     ▼
                                       Postgres 18 + pg_semantic_platform  (:5434)
```

## Quick start

```bash
cd pgrest
cp .env.example .env          # Windows: copy .env.example .env  (pg-rest-create does this for you)
./pg-rest-create.sh           # build the DB image + bring the stack up (Windows: pg-rest-create.cmd)
./pg-rest-api-test.sh         # smoke test: mint a JWT, read data, confirm anon is blocked
```

- **Admin:** http://localhost:7070 · **Docs:** http://localhost:8080 · **API:** http://localhost:3000

## Services & images

Five services (project `semantius-rest`), four long-running + one one-shot:

| Service | Image | Host port | Purpose |
|---|---|---|---|
| `postgres` | `ghcr.io/adenin-platform/semantius-db:${SEMANTIUS_DB_VERSION}` (built from [`../docker-semantius`](../docker-semantius/README.md)) | **5434** | PG18 with the extension installed + roles/pg_hba/authenticator/nwind baked in |
| `jwks-fetch` | `curlimages/curl:latest` | — | **one-shot**: downloads the issuer JWKS to a file PostgREST can read (see below) |
| `postgrest` | `postgrest/postgrest:latest` | **3000** | HTTP API; verifies the JWT vs the JWKS; serves OpenAPI at `/` |
| `scalar` | `scalarapi/api-reference:latest` | **8080** | renders PostgREST's Swagger 2.0 spec as browsable docs |
| `web` | `ghcr.io/intranetfactory/semantius-web:latest` | **7070** | static admin SPA (Caddy also proxies `/api/*` → `postgrest:3000`) |

The registry images use `:latest` and `pull_policy: always` (re-pulled on every
`pg-rest-create`); `postgres` is the locally-built image, used as-is. Pin
`postgrest`/`scalar` to fixed tags once you're happy.

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
| `SEMANTIUS_DB_VERSION` | `latest` | `postgres` | Tag of the `semantius-db` image to run. Pin (e.g. `0.2.0`) for reproducible/server deploys; `latest` tracks your local `docker-semantius/build.sh`. |
| `NWIND` | *(unset)* | `postgres` | Set to **any** non-empty value (e.g. `TRUE`) to load the optional Northwind demo module on first init. Takes effect only on a **fresh** data volume (init runs once). |
| `POSTGRES_PORT` | `5434` | `postgres` | Host port for Postgres (5432/5433 belong to pgdocker's cli/ext stacks). |
| `POSTGREST_PORT` | `3000` | `postgrest`, `scalar` | Host port for the PostgREST HTTP API (OpenAPI spec at `/`). |
| `DOCS_PORT` | `8080` | `scalar` | Host port for the Scalar docs site. |
| `WEB_PORT` | `7070` | `web` | Host port for the admin SPA (serves on container port 80). |
| `PUBLIC_API_URL` | `http://localhost:${POSTGREST_PORT}` | `postgrest`, `scalar` | Browser-reachable base URL of the API. Used for BOTH the OpenAPI spec's advertised server and the docs' spec `url` — both resolved by the browser, so NEVER the in-network `postgrest` hostname. Behind a reverse proxy, set the public URL **including** the path prefix (e.g. `https://you.com/api`); the proxy must strip that prefix. |

> **Going live?** The only variables a real deployment is *required* to change are
> **`VITE_OAUTH_CONFIG`** and **`VITE_OAUTH_CLIENT_ID`** (your OIDC issuer's discovery
> URL + client id). `JWKS_URL` is derived from that discovery document automatically,
> so you normally leave it empty. Everything else has a working default — change the
> passwords too for anything shared or network-exposed.

**Not `.env`-driven — hardcoded in the compose:**

- `POSTGRES_USER` — always `postgres`.
- The **test-token** helpers (`pg-rest-token` / `pg-rest-api-test`) mint from a
  **hardcoded** issuer in `pgdocker/verify_oauth.ts`, not an env var — they're
  test-only, so there's no issuer knob here. The real issuer settings are the
  `VITE_OAUTH_*` pair and `JWKS_URL` above.

The `postgrest` and `web` services also set fixed operational env (`PGRST_*`,
`VITE_API_BASE_URL`, etc.) inline; those are documented by comments in
`docker-compose.yml` and rarely need changing.

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
  rotates signing keys, refresh them on demand with **`./pg-rest-jwks-refresh.sh`**
  (Windows: `pg-rest-jwks-refresh.cmd`) — it re-fetches `JWKS_URL` and restarts
  PostgREST so it re-reads the file (a ~1s API blip; the DB stays up). A restart is
  required rather than a reload signal because the key comes from the
  `PGRST_JWT_SECRET` env var, and PostgREST does **not** re-read env-var config on a
  config reload (`SIGUSR2` / `NOTIFY pgrst 'reload config'`).

  Most IdPs rotate slowly and publish new keys ahead of use, so running this on
  demand is usually enough. **Depending on how often your IdP rotates keys, you may
  want to run it on a schedule** — e.g. a daily cron:
  ```cron
  0 3 * * *  cd /path/to/pgrest && ./pg-rest-jwks-refresh.sh >> /var/log/jwks-refresh.log 2>&1
  ```

## Volumes

| Volume | Mounted by | Holds |
|---|---|---|
| `pgdata` | `postgres` | the database cluster (survives stop/start; removed by `pg-rest-destroy`) |
| `jwks` | `jwks-fetch` (rw), `postgrest` (ro) | the fetched `jwks.json` |

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
created by the extension itself; the `semantius-db` image's baked init scripts only
flip `semantius_authenticator` to LOGIN+password and add the `anon` role — this
stack mounts nothing.

### The OpenAPI docs are public, the data is not

`PGRST_OPENAPI_MODE=ignore-privileges` makes PostgREST emit the **full** spec for
the token-less docs request (so Scalar renders every endpoint) while `anon` still
can't read a single row. `PGRST_OPENAPI_SECURITY_ACTIVE=true` adds a JWT bearer
scheme so the docs show an **Authentication** panel — mint a token with
`./pg-rest-token.sh <user>` and paste `Bearer <token>`.

## Management scripts

Thin wrappers over `docker compose` in this folder (project `semantius-rest`);
each has a `.sh` (bash) and `.cmd` (Windows) form.

| Script | Does | `docker compose` |
|---|---|---|
| `pg-rest-create` | build the DB image (via `../docker-semantius`) + (re)create all containers fresh and start them (copies `.env` on first run) | `up -d --force-recreate --remove-orphans` |
| `pg-rest-start` | start the existing (stopped) containers | `start` |
| `pg-rest-stop` | stop containers, keep them + volumes | `stop` |
| `pg-rest-status` | container status | `ps -a` |
| `pg-rest-destroy` | remove containers, network, and **both volumes** (keeps the image; confirm prompt) | `down -v` |
| `pg-rest-token` | mint a JWT for a test user (paste into the docs / use with curl) | — |
| `pg-rest-jwks-refresh` | re-fetch the issuer JWKS + restart PostgREST to pick up rotated keys (see [Key rotation](#the-jwks-fetch-service--why-it-exists)) | `run --rm jwks-fetch` + `restart postgrest` |
| `pg-rest-api-test` | mint a JWT → read data → confirm anon is blocked (HTTP/auth smoke test) | — |
| `pg-rest-test` | full pgTAP suite against a freshly rebuilt stack (`down -v`, destructive) | — |

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
