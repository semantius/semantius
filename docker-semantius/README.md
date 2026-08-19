# docker-semantius — the Semantius DB image

Builds and publishes the self-contained database image:

```
ghcr.io/adenin-platform/semantius-db:<version>   # + :latest
```

It is **PostgreSQL 18 with the `pg_semantic_platform` extension installed and the
whole runtime baked in**, so a consumer stack (see [`../pgrest`](../pgrest)) is
*just a docker-compose file* — it mounts nothing from the host. On a fresh data
volume the image, driven by a few env vars, sets up:

| Baked-in step (`initdb/`) | Does |
|---|---|
| `10-install-extension.sql` | `CREATE EXTENSION pg_semantic_platform CASCADE` → roles (NOLOGIN), schemas, data dictionary |
| `20-authenticator-login.sh` | flips `semantius_authenticator` to **LOGIN** + sets its password from `$SEMANTIUS_AUTHENTICATOR_PASSWORD` (the one secret-injecting shell step) |
| `30-postgrest-anon.sql` | adds the PostgREST `anon` role (schema USAGE only) |
| `40-nwind.sh` | **optional** — loads the Northwind demo module when `$NWIND` is set |
| `conf/pg_hba.conf` | client auth (activated by the image `CMD`'s `hba_file=`) |

The **extension itself stays self-contained** — `CREATE EXTENSION
pg_semantic_platform` on any bare Postgres gives you the full model with no shell
scripts. This image just adds the deployment layer (LOGIN/password, `anon`,
pg_hba, demo data) that an extension architecturally can't own.

The image version tracks the repo-wide extension version (`extension/META.json`),
so `semantius-db:0.2.0` contains extension `0.2.0`.

## Environment variables

| Var | Default | Effect (first init only) |
|---|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | postgres / — / postgres | stock `postgres` image behaviour (DB created from `POSTGRES_DB`) |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | password for the `semantius_authenticator` LOGIN role |
| `NWIND` | *(unset)* | set to **any** non-empty value (e.g. `TRUE`) to load the Northwind demo module |

> Init scripts run **once**, when the data volume is empty. Changing `NWIND`
> later has no effect unless you recreate the volume.

## The optional Northwind module

`40-nwind.sh` runs `/opt/semantius/nwind.sql`, which the Dockerfile **merges at
build time** from the app's own two migrations —
[`apps/nwind/migrations/0010_create.sql`](../apps/nwind/migrations/0010_create.sql)
(registers the module/entities into the dictionary; triggers auto-create the
tables) and
[`0020_load_data.sql`](../apps/nwind/migrations/0020_load_data.sql) (the sample
rows). Neither redeclares `_core` (that is the extension). The build appends
`_versions` guards so a later `deno task migrate --apps nwind` treats it as
already deployed.

## Scripts

| Script | What it does |
|---|---|
| `./build.sh [version]` | Builds `semantius-db:<version>` + `:latest` **locally** from `./extension` (+ the nwind migrations). Does NOT regenerate the extension. |
| `./publish.sh [version]` | Pushes those tags to GHCR (login required; CI does this on tag). |

Both infer the version from the `./extension` build when no argument is given, and
honour an `IMAGE=` override (default `ghcr.io/adenin-platform/semantius-db`).

> **Changed migrations?** Regenerate the extension first, with an **explicit**
> version — a bare `deno task extension` falls back to the CLI's own `0.1.0` and
> downgrades the build:
> ```bash
> deno task extension 0.2.0
> ```

## Build context

Both `build.sh` and CI (`.github/workflows/extension-release.yml`) build with the
**repo root** as context and `docker-semantius/Dockerfile`. The repo-root
`.dockerignore` whitelists exactly `extension/`, `docker-semantius/`, and
`apps/nwind/migrations/` so the context stays tiny.

## Local development

Build locally, then any consumer stack uses the `:latest` tag without pulling:

```bash
./docker-semantius/build.sh          # from repo root
cd pgrest && docker compose up -d    # uses the local image
```

`pgrest/pg-rest-create.sh` runs `build.sh` for you.

## Publishing

Automatic: push a `v<version>` tag (e.g. `v0.2.0`). The
[`extension-release.yml`](../.github/workflows/extension-release.yml) workflow
generates the extension, cuts the GitHub Release, and pushes the image to GHCR —
one tag, both artifacts, versions in lockstep.

Manual:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <user> --password-stdin
./docker-semantius/build.sh 0.2.0
./docker-semantius/publish.sh 0.2.0
```

## Consuming it

`pgrest/docker-compose.yml` references
`ghcr.io/adenin-platform/semantius-db:${SEMANTIUS_DB_VERSION:-latest}`. Pin
`SEMANTIUS_DB_VERSION` in `.env` for reproducible/server deploys; leave it at
`latest` to track your local build.
