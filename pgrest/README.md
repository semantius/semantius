# pgrest — internal PostgREST API + OpenAPI docs for the extension DB

A self-contained Docker stack that puts an **HTTP API with browsable OpenAPI docs** in front of a
PostgreSQL 18 database carrying the `pg_semantic_platform` extension.

It is the sibling of [`pgdocker/`](../pgdocker/). Where **pgdocker** authenticates clients with
**PostgreSQL-native OAuth** (`pg_oidc_validator` compiled into the image, `oauth` lines in
`pg_hba.conf`; clients connect *directly* to Postgres), **pgrest** fronts the same extension
database with **PostgREST**: PostgREST verifies the OIDC bearer token against the issuer's **JWKS**
and connects to Postgres over SCRAM. Same issuer, same JWKS URL, same `authenticated`/RLS model —
no native-OAuth build, no validator.

```
browser ──▶ Admin SPA   (:7070)
browser ──▶ Scalar docs (:8080) ──fetch spec──▶ PostgREST (:3000, OpenAPI at /)
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET ROLE authenticated | anon  (per request)
                                                     ▼
                                       Postgres 18 + pg_semantic_platform  (:5434)
```

The stack also runs a static **admin SPA** (`ghcr.io/intranetfactory/semantius-web`, served on
container port 80) published on the host at **:7070**.

## Quick start

**Prerequisites:** Docker Desktop running, plus Deno (for the extension build and the token-minting test).

**1. Generate the extension** — *only if you changed migrations.* From the repo root, with an
**explicit** version (a bare `deno task extension` falls back to the CLI's own `0.1.0` and
downgrades the build):

```bash
deno task extension 0.2.0
```

Otherwise the committed build is used as-is. `pg-rest-create` (step 3) builds the DB image
`ghcr.io/adenin-platform/semantius-db` from it via [`../docker-semantius/build.sh`](../docker-semantius/README.md).

**2. Configure.** Create your `.env` from the template:

```bash
cd pgrest
cp .env.example .env          # Windows: copy .env.example .env
```

Edit `.env` to point at your OIDC issuer's JWKS. The defaults use a public **throwaway test
issuer**, so you can skip this to try it out — but change them for anything real:

```ini
ISSUER=https://your-issuer.example.com
JWKS_URL=https://your-issuer.example.com/jwks
```

(Skip this step entirely and `pg-rest-create` copies `.env` from `.env.example` for you — running
against the test issuer.)

**3. Build + start** the stack — Postgres + JWKS fetch + PostgREST + Scalar docs:

```bash
./pg-rest-create.sh           # Windows: pg-rest-create.cmd
```

**4. Verify, then open the docs.** The API test mints a JWT, reads real data, and checks anon is blocked:

```bash
./pg-rest-api-test.sh
```

- **Admin:** http://localhost:7070 — admin single-page app
- **Docs:** http://localhost:8080 — Scalar API reference
- **API:** http://localhost:3000 — OpenAPI spec served at `/`

**5. Stop / resume / wipe:**

```bash
./pg-rest-stop.sh             # stop containers, keep them (and the data)
./pg-rest-start.sh            # start the stopped containers again
./pg-rest-destroy.sh          # remove containers + volumes (keeps the image)
```

## Where do I provide the JWKS?

In **`.env`, as `JWKS_URL`**. PostgREST itself *cannot* fetch a JWKS from a URL (its `jwt-secret`
only accepts inline JSON or a file path), so the `jwks-fetch` service downloads `JWKS_URL` **once at
startup** into a shared file (`/jwks/jwks.json`) that PostgREST reads. That is the only place the
JWKS is configured.

- **Change issuers:** edit `ISSUER` + `JWKS_URL` in `.env`, then `./pg-rest-create.sh` (rebuild) or
  just restart: `docker compose up -d jwks-fetch && docker kill -s SIGUSR1 postgres18-rest-api`
  (re-fetch + reload PostgREST's key without a full restart).
- **Key rotation:** because the JWKS is fetched once per start, if the issuer rotates signing keys,
  refresh it the same way. Fail-closed — if the issuer is unreachable at boot, `jwks-fetch` exits
  non-zero and PostgREST won't start.

Default: the public throwaway test issuer `https://oidc-test.semanti.us` (the same one pgdocker
uses), whose tokens already carry `"role":"authenticated"`, so the stack works out of the box with
zero OIDC setup.

## Configuration (`.env`)

| Var | Default | What it is |
|---|---|---|
| `JWKS_URL` | `https://oidc-test.semanti.us/jwks` | **The JWKS PostgREST validates bearer tokens against.** Point at your issuer. |
| `ISSUER` | `https://oidc-test.semanti.us` | OIDC issuer — used by the test script (token minting) and the docs title. |
| `POSTGRES_PASSWORD` | `postgres` | `postgres` DBA login (used by `DATABASE_URL` / the CLI). |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | Password for `semantius_authenticator`, the role PostgREST logs in as. Also used in `PGRST_DB_URI` — kept in sync automatically. |
| `POSTGRES_PORT` | `5434` | Host port for Postgres (5432/5433 belong to pgdocker's cli/ext stacks). |
| `POSTGREST_PORT` | `3000` | Host port for the HTTP API (OpenAPI spec at `/`). |
| `DOCS_PORT` | `8080` | Host port for the Scalar docs site. |
| `WEB_PORT` | `7070` | Host port for the admin SPA (`ghcr.io/intranetfactory/semantius-web`, serves on 80). |

`.env` is gitignored; `.env.example` is the committed template.

## Managing the stack

Each has a `.sh` (bash) and a `.cmd` (Windows) form:

Clean lifecycle separation — **create** creates, **start**/**stop** only toggle running state, **destroy** is the only one that removes:

| Script | Does | `docker compose` |
|---|---|---|
| `pg-rest-create` | build the DB image (via `../docker-semantius`) + **(re)create** all containers fresh and start them (copies `.env` on first run). Re-pulls the `:latest` registry images (postgrest, scalar, admin SPA, curl — via `pull_policy: always`); the locally-built DB image is used as-is. Always ends in a clean stack — never resumes a stale container. Keeps volumes/data. | `up -d --force-recreate --remove-orphans` |
| `pg-rest-start`  | **start** the existing (stopped) containers — never creates them. Errors if the stack was not created yet. | `start` |
| `pg-rest-stop`   | **stop** the containers without removing them; keeps containers, network, and volumes. | `stop` |
| `pg-rest-status` | show container status (created / running / healthy / exited) | `ps -a` |
| `pg-rest-destroy` | **remove** containers, network, and **both volumes** (keeps the DB image; confirm prompt) | `down -v` |
| `pg-rest-token`  | mint a JWT for a test user — paste into the docs, or use with curl |
| `pg-rest-api-test` | mint a JWT from the issuer → read real data → confirm anon is blocked (HTTP/auth smoke test) |
| `pg-rest-test`   | **full pgTAP suite** against a freshly rebuilt stack + real `CREATE EXTENSION` install (`down -v`, destructive) — the first-time test of a clean install |
| `pg-rest-retest` | fast pgTAP suite in a throwaway DB on the already-running stack (non-destructive) |

Under the hood these are thin wrappers over `docker compose` in this folder (project
`semantius-rest`), so `docker compose logs -f postgrest`, `docker compose ps`, etc. work too.

## Services

| Service      | Image                      | Host port | Role |
|--------------|----------------------------|-----------|------|
| `postgres`   | `ghcr.io/adenin-platform/semantius-db:${SEMANTIUS_DB_VERSION}` (from [`../docker-semantius`](../docker-semantius/README.md)) | `5434` | PG18 + `pg_semantic_platform` baked in |
| `jwks-fetch` | `curlimages/curl`          | —         | one-shot: fetches `JWKS_URL` → shared volume file |
| `postgrest`  | `postgrest/postgrest`      | `3000`    | HTTP API; verifies JWT vs JWKS; serves OpenAPI at `/` |
| `scalar`     | `scalarapi/api-reference`  | `8080`    | renders PostgREST's Swagger 2.0 spec |

5434 keeps it clear of pgdocker's CLI (5432) and ext (5433) stacks, so all three run side by side.

## Auth model (how a request flows)

PostgREST logs in as **`semantius_authenticator`** (SCRAM, `NOSUPERUSER NOINHERIT`) and `SET ROLE`s
per request:

- **Valid bearer token** → PostgREST validates the RS256 signature against `jwks.json`, reads the
  `role` claim (default key `.role`) and does `SET ROLE authenticated`, publishing the token payload
  to `request.jwt.claims`. `rbac.uid()` reads that blob, requires `role='authenticated'` + a
  non-empty `sub`, and RLS takes over. The test issuer already mints `"role":"authenticated"`, so
  this works with no token surgery.
- **No / invalid token** → `SET ROLE anon`. `anon` has schema `USAGE` **only** — no table
  privileges — so any data request fails with *permission denied* before RLS is even consulted.

This is exactly the Supabase/Neon "authenticator → authenticated" pattern documented in
[`apps/_core/migrations/0011_session_authenticator.sql`](../apps/_core/migrations/0011_session_authenticator.sql).
The roles (`authenticated`, `semantius_user`, `semantius_authenticator`) are created by the
extension itself; the init scripts only flip `semantius_authenticator` to LOGIN+password and add the
`anon` role.

### The OpenAPI docs are public, the data is not

`PGRST_OPENAPI_MODE=ignore-privileges` makes PostgREST emit the **full** spec at `/` for the
token-less docs request, so Scalar renders every endpoint — while `anon` still can't read a single
row (no table grants). Getting the *structure* without a token is the point of an internal docs
site; getting *data* still requires a valid token + RLS.

### Trying authenticated calls in the docs

`PGRST_OPENAPI_SECURITY_ACTIVE=true` adds a `JWT` bearer scheme to the spec, so Scalar shows an
**Authentication** panel:

1. Mint a token: `./pg-rest-token.sh user1` (or `user2` / `user3`).
2. In the docs (http://localhost:8080) open **Authentication → JWT** and paste the header value
   **`Bearer <token>`** (include the `Bearer ` prefix — the scheme is a raw `Authorization` header).
3. Run **Test Request** on any endpoint — Scalar sends the header and RLS applies.

Tokens expire, so re-run `pg-rest-token` for a fresh one. Same value works with curl:
`curl -H "Authorization: Bearer $(./pg-rest-token.sh user1)" http://localhost:3000/users`.

## Using the CLI against this stack

A repo-root [`.env.pgrest`](../.env.pgrest) profile points the Deno CLI at port 5434:

```bash
deno task connect --env pgrest                    # test the DBA connection
deno task migrate --apps test --env pgrest        # deploy more apps on top of _core
```

`_core` is already installed (by the extension), so `migrate` only deploys the apps you name. After
each migration the CLI fires `NOTIFY pgrst, 'reload schema'`, which the running PostgREST picks up
automatically (`PGRST_DB_CHANNEL_ENABLED=true`) — no restart needed.

## Notes

- **Keep passwords in sync.** `SEMANTIUS_AUTHENTICATOR_PASSWORD` in `.env` is read by
  `init/11-session-role.sh` *and* used in `PGRST_DB_URI`; the `postgres` password must match the DBA
  password in the repo-root `.env.pgrest`.
- **CORS**: PostgREST allows all origins by default and handles the preflight, so Scalar on `:8080`
  fetching the spec / "Try it out" on `:3000` works with no config. There's no origin allow-list —
  front it with a proxy if you need one.
- **Pin images** (`postgrest/postgrest:vX.Y.Z`, `scalarapi/api-reference:<tag>`) once you're happy;
  the compose file uses `:latest` for a fresh dev start.

> ⚠️ **Test issuer only.** `https://oidc-test.semanti.us` is a public, throwaway OIDC server that
> mints tokens for anyone — it holds no secrets. It exists to exercise the auth path out of the box.
> Point `ISSUER` / `JWKS_URL` in `.env` at your own trusted issuer before deploying anything real.
