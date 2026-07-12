# docker-semantius — the Semantius DB image

Builds and publishes the reusable database image:

```
ghcr.io/adenin-platform/semantius-db:<version>   # + :latest
```

It is **PostgreSQL 18 with the `pg_semantic_platform` extension baked in** — and
nothing else. No PostgREST, no OAuth validator, no role/pg_hba bootstrap. Those
belong to whatever stack runs on top of it (see [`../pgrest`](../pgrest)). Keeping
this image runtime-agnostic is what lets any stack — or a Dokploy template — pull
it and build a backend on top.

The image version tracks the repo-wide extension version (`extension/META.json`),
so `semantius-db:0.2.0` contains extension `0.2.0`.

## Scripts

| Script | What it does |
|---|---|
| `./build.sh [version]` | Builds `semantius-db:<version>` + `:latest` **locally** from the files in `./extension`. Does NOT regenerate the extension. |
| `./publish.sh [version]` | Pushes those tags to GHCR (login required; CI does this on tag). |

Both infer the version from the `./extension` build when no argument is given, and
honour an `IMAGE=` override (default `ghcr.io/adenin-platform/semantius-db`).

> **Changed migrations?** Regenerate the extension first, with an **explicit**
> version — a bare `deno task extension` falls back to the CLI's own `0.1.0` and
> downgrades the build:
> ```bash
> deno task extension 0.2.0
> ```

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
