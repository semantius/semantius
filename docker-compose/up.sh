#!/usr/bin/env bash
# up.sh  -  (re)create the PostgREST stack's CONTAINERS from the current compose
# config and start them, KEEPING the database.
#
# This is `docker compose up --force-recreate`. Reach for it after changing
# docker-compose.yml, .env or the Caddyfile: the containers are replaced, your
# data survives.
#
# It does NOT give you a clean database. The image's first-init scripts
# (CREATE EXTENSION, the authenticator LOGIN, anon, the optional NWIND load) run
# ONCE per data directory, so an existing pgdata volume keeps the OLD schema no
# matter how many times the containers are recreated. For a fresh database — and
# for any honest test of an image — use ./create.sh, which wipes the volume first.
#
# IMAGES COME FROM THE REGISTRY by default, like every other service in this
# stack: the DB image is PULLED from GHCR, so this works in a fresh clone with no
# Deno, no ./extension and no local build. Pass --build to run YOUR working tree
# instead (that is the development loop, not the default).
#
# Usage:
#   ./up.sh                  pull the published DB image, then up
#   ./up.sh 0.4.0-pg18       ... pinned to that tag (overrides SEMANTIUS_DB_VERSION)
#   ./up.sh --build          build the image from ../extension instead of pulling
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '/^# Usage:/,/instead of pulling/p' "$0" | sed 's/^# \{0,1\}//'; }

PULL=1; DB_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build)   PULL=0 ;;
    --pull)    PULL=1 ;;   # the default; accepted so it can be stated explicitly
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)         DB_VERSION="$1" ;;   # a bare argument is the image tag
  esac
  shift
done

# A tag selects a PUBLISHED image; build.sh tags whatever ../extension holds, so
# the two cannot be combined without lying about what is running.
if [ "$PULL" = 0 ] && [ -n "$DB_VERSION" ]; then
  echo "A version tag ('$DB_VERSION') applies only when pulling — --build runs whatever ../extension holds." >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit passwords/ports if you want."
fi

# An explicit tag wins over .env: the shell environment takes precedence over the
# .env file in docker compose's variable resolution.
if [ -n "$DB_VERSION" ]; then
  export SEMANTIUS_DB_VERSION="$DB_VERSION"
  echo "Pinning SEMANTIUS_DB_VERSION=${DB_VERSION} for this run."
fi

# The tag we are about to run, resolved the same way compose resolves it
# (shell env > .env > the `:-latest` default) — for the messages below only.
# Captured NOW because the summary at the end re-sources .env.
env_tag="$(grep -E '^SEMANTIUS_DB_VERSION=' .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true)"
IMAGE_TAG="${SEMANTIUS_DB_VERSION:-${env_tag:-latest}}"

if [ "$PULL" = 1 ]; then
  # The other services are `pull_policy: always`; `postgres` is not, because a
  # local --build must survive an `up`. So pull it explicitly here.
  # NOTE: pulling `latest` OVERWRITES an image left by a previous --build.
  echo "== Pulling the published DB image (:${IMAGE_TAG}) =="
  docker compose pull postgres
else
  # Package ./extension into the image and tag it :latest, so the compose
  # `image:` resolves to your current source without pulling.
  echo "== Building the DB image from local source =="
  ../docker-postgres/build.sh
fi

# --force-recreate: always replace existing containers with fresh ones built from
# the current compose config, so this can never resume a stale/half-built container
# (e.g. one left port-unpublished by an earlier failed `up`). --remove-orphans drops
# containers for services no longer in the compose file. Data lives in named
# volumes, so this does NOT lose data — only ./create.sh and ./destroy.sh do.
docker compose up -d --force-recreate --remove-orphans
docker compose ps

set -a; . ./.env; set +a
echo
echo "Ready (PostgREST stack)."
echo "  Image : ghcr.io/semantius/postgres:${IMAGE_TAG}  ($([ "$PULL" = 1 ] && echo pulled || echo 'built from local source'))"
echo "  Admin : http://localhost:${WEB_PORT:-3000}/   (SPA; API at /rest/, docs at /api-docs/)"
echo "  IdP   : http://localhost:${WEB_PORT:-3000}/idp   (first run: create the first administrator)"
echo "  API   : http://localhost:${POSTGREST_PORT:-3100}/   (OpenAPI spec at /)"
echo "  Docs  : http://localhost:${DOCS_PORT:-8080}/         (Scalar API reference)"
echo "  DBA   : postgresql://postgres:<POSTGRES_PASSWORD>@localhost:${POSTGRES_PORT:-5434}/semantius"
