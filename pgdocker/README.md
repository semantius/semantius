# PostgreSQL 18 + OAuth/JWT — self-host target for Semantius Core

A Docker image and Compose stack that runs **PostgreSQL 18** preconfigured as a
third deployment target for Semantius Core — alongside Supabase and Neon — so
you can self-host on any PostgreSQL 18+ server **without** a managed provider.

It does two things:

1. **A full-DBA login** (`postgres`, password/SCRAM) — what `DATABASE_URL`
   points at for deploying migrations and admin (the Semantius CLI, `psql`, …).
2. **OAuth/JWT auth for application connections** — clients present an OIDC
   access token; PostgreSQL verifies it natively (SASL `OAUTHBEARER`) against
   the issuer's JWKS and maps it to the **`authenticated`** role — the *same*
   role name Supabase and Neon use for authenticated end users.

> ⚠️ The OAuth validator (`pg_oidc_validator`) is **experimental and not
> production-ready** per its authors. There is no mature, blessed validator for
> PG18 OAuth yet. Treat this as a working starting point, not a hardened deploy.

---

## How it actually works (read this first)

PostgreSQL 18 added native OAuth via SASL `OAUTHBEARER`, **but the server does
not validate tokens itself and ships no built-in validator.** You must load a
validator module. This image compiles Percona's
[`pg_oidc_validator`](https://github.com/percona/pg_oidc_validator), which:

- resolves the issuer's JWKS via `<issuer>/.well-known/openid-configuration` →
  `jwks_uri`,
- verifies each access token's RS256 signature against those keys, and
- extracts the identity claim (default `sub`) so PostgreSQL can map it to a role.

### The two roles

| Role            | Auth method        | Used by                              | LOGIN |
| --------------- | ------------------ | ------------------------------------ | ----- |
| `postgres`      | password (SCRAM)   | migrations / admin (`DATABASE_URL`)  | yes   |
| `authenticated` | OAuth (`OAUTHBEARER`) | application end-user connections  | yes   |

`authenticated` is created with **`LOGIN`** ([init/10-roles.sql](init/10-roles.sql)).
This differs from the Supabase/Neon **PostgREST** model, where `authenticated`
is `NOLOGIN` and PostgREST logs in as `authenticator` and `SET ROLE`s into it.
Here clients connect **directly** and authenticate *as* `authenticated`, so the
role must be able to log in. The Semantius core migrations create
`semantius_user`, grant it the table/schema privileges, then grant
`semantius_user` → `authenticated`, so `authenticated` inherits its runtime
rights from there.

### Identity → role mapping

[conf/pg_hba.conf](conf/pg_hba.conf) carries `map="oidc"`, and
[conf/pg_ident.conf](conf/pg_ident.conf) maps **every** validated token identity
to `authenticated`:

```
# MAPNAME   SYSTEM-USERNAME   PG-USERNAME
oidc        /^(.*)$           authenticated
```

The token's own `sub` still identifies the individual user to the application
via the JWT claims (next section).

### Claims in the session — published by the bundled validator patch

PostgreSQL's stock OAuth interface only surfaces the *identity* (`authn_id` →
`system_user`); the rest of the verified claims are discarded. Semantius RLS,
however, reads the user from the GUC `request.jwt.claims`, exactly as PostgREST
sets it on Supabase/Neon. So this image ships a one-line patch to the validator
— [patches/0001-publish-jwt-claims.patch](patches/0001-publish-jwt-claims.patch)
— that publishes the **full, signature-verified payload** into
`request.jwt.claims` at connect time:

```cpp
res->authn_id = pstrdup(payload.at(authn_field).to_str().c_str());
SetConfigOption("request.jwt.claims",
                picojson::value(payload).serialize().c_str(),
                PGC_USERSET, PGC_S_SESSION);   // <- the patch
```

The GUC survives into the session (verified — see below), so **OAuth
connections work with RLS out of the box**, with no application cooperation:

```
$ deno run --allow-net verify_oauth.ts
AuthenticationOk: OAUTHBEARER token accepted
OK  current_user=authenticated  system_user=oauth:user1
    request.jwt.claims = {"sub":"user1","role":"authenticated","email":"user@test.com", ...}
```

`rbac.uid()` requires `role = 'authenticated'` and a non-empty `sub`; the test
tokens carry both, so it just works — no app step, no extension.

### Identity comes from the validated session, not the claims

Because clients connect **directly** (no PostgREST in between), `request.jwt.claims`
is set within the session and so is treated as a convenience, not proof of identity.
For OAuth sessions, core's `rbac.uid()` takes the subject from `system_user`
(`oauth:<sub>`, which PostgreSQL validated from the bearer token and a client cannot
forge), ignoring any client-set `sub`. (The Supabase/Neon PostgREST path,
`system_user = scram-sha-256:authenticator`, is unaffected.) Writes to the `users`
table additionally require the `user:manage` permission via RLS, so only admins can
change user rows; first-login provisioning runs through a `SECURITY DEFINER` function
that only ever touches the caller's own row.

> **Why not `pg_session_jwt`?** That Neon extension *re-validates* a raw JWT
> injected into a session var and exposes it via `auth.user_id()`. Here the
> token is already validated by PG18 OAuth (against the same JWKS), so it would
> be redundant — and it speaks a different claim API than the `request.jwt.*`
> convention this codebase (and the Neon **Data API** / Supabase) already uses.
> It fits Neon's proxy-injection model, not PG18 native OAuth.

---

## Quick start

```bash
cp .env.example .env          # set POSTGRES_PASSWORD
docker compose up --build     # first build compiles the validator (~1-3 min)
```

The full-DBA connection string is then:

```
postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5432/appdb
```

Point the Semantius CLI at it and deploy:

```bash
export DATABASE_URL=postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5432/appdb
deno task reset --confirm     # drop + migrate _core,cloud
deno task retest --confirm    # migrate test + run pgTAP
```

---

## Managing the container (prepare / start / stop / destroy)

This folder ships ready-to-run lifecycle scripts — `.sh` for macOS/Linux/Git-Bash
and `.cmd` for Windows (double-click in Explorer, or run from a terminal):

| Action | bash | Windows | Effect |
| ------ | ---- | ------- | ------ |
| Create | `./create.sh` | `create.cmd` | build image + create `.env` (if missing) + start |
| Start  | `./start.sh`  | `start.cmd`  | start (reuse existing image) |
| Stop   | `./stop.sh`   | `stop.cmd`   | remove container+network, **keep data** |
| Delete | `./delete.sh` | `delete.cmd` | remove container+network+**data volume**+image (asks to confirm) |

The scripts just wrap the `docker compose` commands below; reach for the raw
commands when you need a one-off. Both are run from this `pgdocker/` folder; only
env vars and the file copy differ between shells.

**Windows (PowerShell)**

```powershell
cd pgdocker
Copy-Item .env.example .env          # PREPARE: then edit .env -> POSTGRES_PASSWORD
docker compose up -d --build         # START  (first build compiles the validator)
docker compose ps                    # wait for "(healthy)"
$env:DATABASE_URL = "postgresql://postgres:<PW>@localhost:5432/appdb"

docker compose stop                  # STOP, keep data  (resume: docker compose start)
docker compose down                  # remove container+network, KEEP data volume
docker compose down -v               # DESTROY: also delete the data volume (DATA GONE)
docker compose down -v --rmi local   # also delete the built image (fully clean)
```

**bash**

```bash
cd pgdocker
cp .env.example .env                 # PREPARE: then edit .env -> POSTGRES_PASSWORD
docker compose up -d --build         # START
docker compose ps
export DATABASE_URL="postgresql://postgres:<PW>@localhost:5432/appdb"

docker compose stop                  # STOP, keep data  (resume: docker compose start)
docker compose down                  # remove container+network, KEEP data volume
docker compose down -v               # DESTROY: also delete the data volume (DATA GONE)
docker compose down -v --rmi local   # also delete the built image (fully clean)
```

What each teardown level actually removes:

| Command | Container | Network | Data volume | Image |
| ------- | --------- | ------- | ----------- | ----- |
| `stop`  | stopped (kept) | kept | **kept** | kept |
| `down`  | removed | removed | **kept** | kept |
| `down -v` | removed | removed | **deleted** | kept |
| `down -v --rmi local` | removed | removed | **deleted** | removed |

`down` is safe — a later `up -d` recreates the container on the same data. `down -v`
is the real "destroy". Useful extras (any shell):

```bash
docker compose logs -f                                   # follow logs
docker compose ps                                        # status / health
docker exec -it postgres18-oauth psql -U postgres -d appdb   # a shell into the DB
```

---

## The test OIDC server

This stack is preconfigured against the test issuer
**`https://test-oidc-server.ma532.workers.dev`**, which mints tokens without an
interactive login — handy for verifying the OAuth path.

```bash
# Mint an access token for a test user (no login required)
curl "https://test-oidc-server.ma532.workers.dev/getaccesstoken?user_id=user1&client_id=test-client"
```

Its tokens already match what Semantius expects:

```json
{
  "iss":   "https://test-oidc-server.ma532.workers.dev",
  "sub":   "user1",
  "aud":   ["test-client", "api://default"],
  "scope": "openid profile email",
  "email": "user@test.com",
  "name":  "John Smith",
  "role":  "authenticated"
}
```

Test users: `user1` (John Smith), `user2` (María García), `user3` (Wei Chen).
Discovery: `/.well-known/openid-configuration` · JWKS: `/jwks`.

To use a different issuer, edit the `issuer=` (and `scope=`) values in
[conf/pg_hba.conf](conf/pg_hba.conf) and rebuild. The issuer must serve an HTTPS
discovery document whose `jwks_uri` points at its JWKS.

---

## Testing the OAuth connection

`psql`/libpq in PG18 speaks OAuth, but the built-in client flow needs the issuer
to advertise a `device_authorization_endpoint` (the test issuer does not). So
this folder ships [verify_oauth.ts](verify_oauth.ts) — a dependency-free Deno
script that mints a fresh token from the test issuer and performs the
`OAUTHBEARER` SASL handshake by hand:

```bash
# DBA login (the DATABASE_URL path):
docker exec -e PGPASSWORD=<PW> postgres18-oauth \
  psql "host=127.0.0.1 user=postgres dbname=appdb" -c "select 1"

# OAuth -> authenticated path (validator + JWKS + ident map + claims):
deno run --allow-net verify_oauth.ts
# minted token for sub=user1 (len=756)
# server offered SASL mechanisms: [ "OAUTHBEARER" ]
# AuthenticationOk: OAUTHBEARER token accepted
# OK  current_user=authenticated  system_user=oauth:user1
#     request.jwt.claims = {"sub":"user1","role":"authenticated", ...}
```

A successful validation requires the container to reach the issuer's HTTPS JWKS
endpoint outbound. Note `system_user=oauth:user1`: PostgreSQL records the
**validated** identity as `oauth:<sub>` — see the claims-bridge section above
for why that matters.

---

## Automated checks (CI)

Both scripts are dependency-free Deno (stdlib only) and exit non-zero on failure,
so they drop straight into CI once the container is healthy:

```bash
docker compose up -d --build
until docker exec postgres18-oauth pg_isready -U postgres -d appdb; do sleep 1; done

# deploy core so rbac.uid() exists, then run the checks
export DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5432/appdb"
deno task migrate --apps _core
deno run --allow-net verify_oauth.ts          # OAuth validated + claims published -> exit 0
deno run --allow-net test_oauth_security.ts   # impersonation attempt is blocked   -> exit 0
```

(Outbound HTTPS to the issuer's JWKS endpoint is required.)

---

## TLS

- The issuer / JWKS endpoints **must be HTTPS** — PostgreSQL enforces this.
- The client↔server connection uses `host` (no TLS) here for local convenience.
  Bearer tokens are sensitive: for any non-local deployment, configure server
  certs and switch the `oauth` lines in [conf/pg_hba.conf](conf/pg_hba.conf)
  from `host` → `hostssl`.

---

## Cross-platform

The base `postgres:18` image is multi-arch (linux/amd64 + linux/arm64) and the
validator is compiled from source during the build, so the **same** Dockerfile
produces a working image on:

- **Linux** (x86-64 and ARM),
- **macOS** (Apple Silicon and Intel) via Docker Desktop,
- **Windows** (x64 and **ARM64**) via Docker Desktop / WSL2.

Docker always builds and runs the container for its own Linux VM architecture,
so no host-specific changes are needed.

---

## Files

- [Dockerfile](Dockerfile) — `postgres:18` + the validator (pinned commit + local patch)
- [docker-compose.yml](docker-compose.yml) — service, volumes, validator/HBA/ident wiring, healthcheck
- [conf/pg_hba.conf](conf/pg_hba.conf) — full-DBA SCRAM lines + the `oauth` rules
- [conf/pg_ident.conf](conf/pg_ident.conf) — token identity → `authenticated` role map
- [init/10-roles.sql](init/10-roles.sql) — creates the `authenticated` LOGIN role
- [patches/](patches/) — validator patch that publishes `request.jwt.claims`
- [verify_oauth.ts](verify_oauth.ts) — end-to-end OAuth handshake + claims check
- [test_oauth_security.ts](test_oauth_security.ts) — hostile-client impersonation check
- [.env.example](.env.example) — DBA password, DB name, host port

## Using it as the devcontainer database

The repo's [.devcontainer](../.devcontainer) brings this image up as the `db`
service, so the whole project runs with no Neon/Supabase account — see
[../.devcontainer/docker-compose.yml](../.devcontainer/docker-compose.yml).
