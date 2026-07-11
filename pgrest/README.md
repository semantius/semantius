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
browser ──▶ Scalar docs (:8080) ──fetch spec──▶ PostgREST (:3000, OpenAPI at /)
                                                     │  SCRAM as semantius_authenticator
                                                     │  SET ROLE authenticated | anon  (per request)
                                                     ▼
                                       Postgres 18 + pg_semantic_platform  (:5434)
```

## Quick start

**Prerequisites:** Docker Desktop running, plus Deno (for the extension build and the token-minting test).

**1. Generate the extension** — from the repo root; it gets baked into the Postgres image:

```bash
deno task extension
```

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

**4. Verify, then open the docs.** The test mints a JWT, reads real data, and checks anon is blocked:

```bash
./pg-rest-test.sh
```

- **Docs:** http://localhost:8080 — Scalar API reference
- **API:** http://localhost:3000 — OpenAPI spec served at `/`

**5. Stop / resume / wipe:**

```bash
./pg-rest-stop.sh             # stop, keep the database
./pg-rest-start.sh            # resume
./pg-rest-delete.sh           # remove containers + volumes + image
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

`.env` is gitignored; `.env.example` is the committed template.

## Managing the stack

Each has a `.sh` (bash) and a `.cmd` (Windows) form:

| Script | Does |
|---|---|
| `pg-rest-create` | build the image + start all services (copies `.env` on first run) |
| `pg-rest-start`  | start/resume existing containers (reuses the image) |
| `pg-rest-stop`   | stop + remove containers; **keeps** the data + jwks volumes |
| `pg-rest-status` | show container status (running / healthy / exited) |
| `pg-rest-delete` | remove containers, network, **both volumes**, and the built image (confirm prompt) |
| `pg-rest-token`  | mint a JWT for a test user — paste into the docs, or use with curl |
| `pg-rest-test`   | mint a JWT from the issuer → read real data → confirm anon is blocked |

Under the hood these are thin wrappers over `docker compose` in this folder (project
`semantius-rest`), so `docker compose logs -f postgrest`, `docker compose ps`, etc. work too.

## Services

| Service      | Image                      | Host port | Role |
|--------------|----------------------------|-----------|------|
| `postgres`   | `postgres18-rest:local` (built from `Dockerfile`) | `5434` | PG18 + `pg_semantic_platform` baked in |
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
