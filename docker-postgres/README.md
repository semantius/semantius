# docker-postgres — the Semantius DB image

Builds and publishes the self-contained database image:

```
ghcr.io/semantius/postgres:<version>-pg<major>   # canonical; moves while newest
ghcr.io/semantius/postgres:latest-pg<major>      # moving, major pinned
ghcr.io/semantius/postgres:latest                # moving, default major
```

It is **PostgreSQL 18 with the `pg_semantius` extension installed and the
whole runtime baked in**, so a consumer stack (see
[semantius-self-hosted](https://github.com/semantius/semantius-self-hosted)) is
*just a docker-compose file* — it mounts nothing from the host. On a fresh data
volume the image, driven by a few env vars, sets up:

| Baked-in step (`initdb/`) | Does |
|---|---|
| `10-install-extension.sql` | `CREATE EXTENSION pg_semantius` then `SELECT semantius.migrate()` → roles (NOLOGIN), schemas, data dictionary. No `CASCADE`: pgcrypto is created by `migrate()`, in `public`. |
| `20-authenticator-login.sh` | flips `semantius_authenticator` to **LOGIN** + sets its password from `$SEMANTIUS_AUTHENTICATOR_PASSWORD` (the one secret-injecting shell step) |
| `30-postgrest-anon.sql` | adds the PostgREST `anon` role (schema USAGE only) |
| `40-nwind.sh` | **optional** — loads the Northwind demo module when `$NWIND` is set |
| `conf/pg_hba.conf` | client auth (activated by the image `CMD`'s `hba_file=`) |

The **extension itself stays self-contained** — `CREATE EXTENSION
pg_semantius` on any bare Postgres gives you the full model with no shell
scripts. This image just adds the deployment layer (LOGIN/password, `anon`,
pg_hba, demo data) that an extension architecturally can't own.

The image version tracks the repo-wide extension version (`extension/META.json`),
so `semantius/postgres:0.3.0-pg18` contains extension `0.3.0` on PostgreSQL 18.
The `-pg<major>` suffix comes from the Dockerfile's `FROM postgres:` line, so one
release can ship the same extension version for several majors side by side.
There is deliberately **no bare `:0.3.0`** — a version tag that silently changed
major later is the ambiguity the suffix removes.

## Environment variables

| Var | Default | Effect (first init only) |
|---|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | postgres / — / postgres | stock `postgres` image behavior (DB created from `POSTGRES_DB`) |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | password for the `semantius_authenticator` LOGIN role |
| `NWIND` | *(unset)* | set to **any** non-empty value (e.g. `TRUE`) to load the Northwind demo module |

> Init scripts run **once**, when the data volume is empty. Changing `NWIND`
> later has no effect unless you recreate the volume.

## The optional Northwind module

The Dockerfile copies [`apps/nwind/migrations/`](../apps/nwind/migrations/) into
the image unmerged and unmodified —
[`0010_create.sql`](../apps/nwind/migrations/0010_create.sql) (registers the
module/entities into the dictionary; triggers auto-create the tables) and
[`0020_load_data.sql`](../apps/nwind/migrations/0020_load_data.sql) (the sample
rows). Neither redeclares `_core` (that is the extension).

`40-nwind.sh` then applies them **exactly as `deno task migrate --apps nwind`
would**: files in name order, one transaction per file, each recorded in
`public._versions` as `nwind.<file>` with the SHA-256 of its LF-normalized text
— in that same transaction, so applied SQL and its `_versions` row can never
disagree. A file already recorded is skipped, so a later `migrate --apps nwind`
is a no-op.

It replicates the runner instead of calling it because it cannot call it: the
initdb temp server listens on the unix socket only (`listen_addresses=''`) and
the CLI's driver speaks TCP. **Its contract is
[`packages/core/src/migrate.ts`](../packages/core/src/migrate.ts)
(`executeMigrations`) — if that changes, `40-nwind.sh` must change with it**, and
`./test-image.sh` is what checks the two still agree.

## Scripts

| Script | What it does |
|---|---|
| `./build.sh [version]` | Builds `semantius/postgres:<version>-pg<major>` + `:latest-pg<major>` + `:latest` **locally** from `./extension` (+ the nwind migrations). Does NOT regenerate the extension. |
| `./publish.sh [version]` | Pushes those tags to GHCR (login required; CI does this on tag). |
| `./test-image.sh [tag]` | Builds the image, then **starts** it twice on fresh data dirs — `NWIND=TRUE` and unset — and asserts first init completes and the demo module is (or is not) there. `--no-build` or a tag tests an image as it stands. |

All three infer the version from the `./extension` build when no argument is given,
and honor an `IMAGE=` override (default `ghcr.io/semantius/postgres`).

`test-image.sh` is the only check that runs the init scripts at all. The pgTAP
suites and `docker-compose/test.sh` both install the Northwind module with
`deno task migrate`; nothing else exercises `40-nwind.sh`, which is a second
implementation of that runner. It asserts the two produce the same database —
same `_versions` names, same checksums — and derives the migration list from
`apps/nwind/migrations/` rather than naming files, so a migration the image fails
to ship is a test failure. Run it before publishing a version.

> **Changed migrations?** Regenerate the extension first. The version is
> required — `deno task extension` refuses without one, because the old fallback
> to the CLI's own `0.1.0` silently downgraded the build:
> ```bash
> deno task extension 0.5.0
> ```
> A version may be regenerated while it is the newest build, and is frozen once a
> higher one is committed; see [RELEASE.md](../RELEASE.md).

## Build context

Both `build.sh` and CI (`.github/workflows/extension-release.yml`) build with the
**repo root** as context and `docker-postgres/Dockerfile`. The repo-root
`.dockerignore` whitelists exactly `extension/`, `docker-postgres/`, and
`apps/nwind/migrations/` so the context stays tiny.

## Local development

Build locally, then run a consumer stack on the `:latest` tag **without pulling**
— the pull would overwrite the image you just built:

```bash
./docker-postgres/build.sh                          # from repo root; tags :latest
cd ../semantius-self-hosted && ./up.sh --no-pull    # or ./create.sh -y --no-pull for a fresh DB
```

The stack's `create.sh` (fresh database) and `up.sh` (keeps the data) **pull** the
published image by default; `--no-pull` makes them run whatever `:latest` is
already present locally.

The whole loop — regenerate the extension, build the image, create the stack on
it, migrate and run the pgTAP suite — is [`../docker-compose/test.sh`](../docker-compose/README.md).

## Publishing

Automatic: push a `v<version>` tag (e.g. `v0.3.0`). The
[`extension-release.yml`](../.github/workflows/extension-release.yml) workflow
generates the extension, cuts the GitHub Release, and pushes the image to GHCR —
one tag, both artifacts, versions in lockstep.

Releases go through [`./release.sh v<version>`](../RELEASE.md), which
builds the image locally as a check and lets the workflow publish it. These two
scripts are for building or pushing an image **outside** a release:

```bash
./docker-postgres/build.sh 0.5.0
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <user> --password-stdin
./docker-postgres/publish.sh 0.5.0
```

Both apply the moving `:latest*` tags only when the version is the highest `v*`
tag in the repo, so building or pushing an older version cannot drag `:latest`
backwards.

## Consuming it

The self-hosting stack's `docker-compose.yml`
([semantius-self-hosted](https://github.com/semantius/semantius-self-hosted))
references `ghcr.io/semantius/postgres:${SEMANTIUS_DB_VERSION:-latest}`. Pin
`SEMANTIUS_DB_VERSION` in its `.env` for reproducible/server deploys; leave it at
`latest` to track the moving published tag (or run its `create`/`up` with
`--no-pull` to use your local build instead).
