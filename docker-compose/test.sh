#!/usr/bin/env bash
# test.sh  -  Test the EXACT PostgREST deployment behavior end to end: a FRESH
# container, a FRESH data volume, and `_core` installed the real way via
# `CREATE EXTENSION pg_semantius` (the whole _core install in ONE
# transaction) — then deploy nwind,test and run the full pgTAP suite.
#
# This is the FIRST-TIME test of a clean install (not a re-test): it rebuilds the
# stack from current source, so it also exercises the image build, the baked init
# scripts (install-extension, authenticator-login, anon) and role bootstrap FROM
# SCRATCH — i.e. the real production install path. It is the PostgREST twin of
# pgdocker/pg-ext-retest.sh.
#
# Why recreate instead of reset-in-place? Local Docker makes a fresh container
# cheap, so we get true fidelity. The CLI `retest` (packages/cli/commands/retest.ts)
# resets in place because it targets hosted Postgres (e.g. Neon) where you cannot
# drop/recreate the database behind a fixed connection string — and it installs
# `_core` via the migrate path (per-file BEGIN/COMMIT), which cannot see the
# single-transaction CREATE EXTENSION defects this script is built to catch.
#
# REQUIRES A CHECKOUT OF github.com/semantius/semantius-self-hosted — the compose
# stack itself lives there, not in this repo. Expected as a sibling of this repo
# (../../semantius-self-hosted); override with SELF_HOSTED_DIR.
#
# DESTRUCTIVE: wipes the stack's data volume and rebuilds it. PROMPTS for
# confirmation first (like the stack's destroy.sh); bypass with -y/--yes or
# ASSUME_YES=1 / CI=true. Afterwards the stack holds the nwind,test fixtures; run
# the stack's ./create.sh for a clean semantius again.
#
# Usage:
#   ./test.sh                test LOCAL source: regenerate the extension, build the
#                            image, run the suite   (the default — this is the
#                            pre-release check that YOUR migrations install cleanly)
#   ./test.sh --pull         test the PUBLISHED image, pulled fresh from GHCR
#   ./test.sh 0.4.0-pg18     ... pinned to that tag (a tag always implies --pull)
#   -y/--yes                 skip the confirmation prompt
#
# NOTE the default is the opposite way round from create/up, deliberately: they are
# stack operations, so they run the registry image like every other service; this is
# a source-testing tool, so it defaults to the source you are sitting on. --pull is
# the post-release check — it skips the extension regen + image build and runs the
# suite against exactly what a consumer/server pulls, on a FRESH volume.
#
# Steps:
#   0. deno task extension <ver>   regenerate the extension SQL from the CURRENT
#                     migrations so the rebuilt image bakes what you just changed
#                     (build.sh packages ./extension as-is; skip with SKIP_EXT_REGEN=1
#                     — and skipped implicitly by --pull, which tests published bits).
#   0b. build.sh      package ./extension into ghcr.io/semantius/postgres:latest
#                     (local source only — the stack itself never builds).
#   1. create -y      wipe the stack + its data volume, pull (or, for local source,
#                     --no-pull so the image just built survives), bring it up
#                     fresh; init runs CREATE EXTENSION (installs _core in ONE txn,
#                     seeds the _versions guard rows).
#   2. readiness gate poll pg_extension until the extension is present (the
#                     pg_isready healthcheck can go green before init finishes).
#   3. migrate --apps nwind,test   migrate auto-prepends _core, SKIPPED because the
#                     extension seeded _versions; only nwind,test deploy.
#   4. test           run the full pgTAP suite against the extension DB.
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd .. && pwd)"
CONTAINER="semantius-postgres"

# The compose stack lives in its own repo now. Default to a sibling checkout.
SELF_HOSTED_DIR="${SELF_HOSTED_DIR:-$REPO_ROOT/../semantius-self-hosted}"
if [ ! -f "$SELF_HOSTED_DIR/docker-compose.yml" ]; then
  echo "No stack found at '$SELF_HOSTED_DIR'." >&2
  echo "Clone it:  git clone https://github.com/semantius/semantius-self-hosted" >&2
  echo "or point SELF_HOSTED_DIR at your checkout." >&2
  exit 1
fi
SELF_HOSTED_DIR="$(cd "$SELF_HOSTED_DIR" && pwd)"

# The DBA connection is derived from the stack's live .env (NOT hard-coded: a
# checked-out .env may differ from .env.example).
if [ ! -f "$SELF_HOSTED_DIR/.env" ]; then
  cp "$SELF_HOSTED_DIR/.env.example" "$SELF_HOSTED_DIR/.env"
  echo "Created $SELF_HOSTED_DIR/.env from .env.example."
fi
read_env() { grep -E "^$1=" "$SELF_HOSTED_DIR/.env" 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"; PW="${PW:-postgres}"
PORT="$(read_env POSTGRES_PORT)";  PORT="${PORT:-5434}"
DB="$(read_env POSTGRES_DB)";      DB="${DB:-semantius}"
REST_URL="postgresql://postgres:${PW}@localhost:${PORT}/${DB}"

# Safety: this DESTROYS the running PostgREST stack + its data volume (down -v) and
# rebuilds it. Confirm before any changes — same guard as destroy.sh.
# Bypass for automation: pass -y/--yes, or set ASSUME_YES=1 or CI=true.
FORCE=0
PULL=0
BUILD=0
DB_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) FORCE=1 ;;
    --pull)   PULL=1 ;;
    --build)  BUILD=1 ;;   # the default; accepted so it can be stated explicitly
    -*) echo "Unknown option: $1 (usage: ./test.sh [--pull|--build] [<version>] [-y])" >&2; exit 1 ;;
    *)  DB_VERSION="$1" ;;   # a bare argument is the image tag
  esac
  shift
done

# A tag names a PUBLISHED image, so it implies --pull and cannot combine with
# --build (which runs whatever ../extension holds).
if [ "$BUILD" = 1 ] && { [ "$PULL" = 1 ] || [ -n "$DB_VERSION" ]; }; then
  echo "--build tests local source; drop --pull / the version tag." >&2
  exit 1
fi
if [ -n "$DB_VERSION" ]; then PULL=1; fi

if [ "$FORCE" != "1" ] && [ "${ASSUME_YES:-}" != "1" ] && [ "${CI:-}" != "true" ]; then
  read -r -p "This DESTROYS the running PostgREST stack and WIPES its data volume ('${DB}', all data), then rebuilds. Continue? [y/N] " ans
  case "$ans" in
    y|Y) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

# [0/5] Regenerate the extension from CURRENT migrations, so the rebuilt image
# tests what is on disk now. Version inferred from the newest built extension SQL,
# exactly like docker-postgres/build.sh.
if [ "$PULL" = 1 ]; then
  echo "== [0/4] Skipped — --pull tests the PUBLISHED image, not local source =="
elif [ "${SKIP_EXT_REGEN:-0}" != "1" ]; then
  VERSION="$(ls "$REPO_ROOT"/extension/pg_semantius--*.sql 2>/dev/null \
    | sed -E 's/.*--([0-9.]+)\.sql/\1/' | sort -V | tail -1)"
  if [ -z "$VERSION" ]; then
    echo "Cannot infer extension version. Run 'deno task extension <ver>' once, or set SKIP_EXT_REGEN=1." >&2
    exit 1
  fi
  echo "== [0/4] Regenerating the extension SQL from current migrations (v$VERSION) =="
  ( cd "$REPO_ROOT" && deno task extension "$VERSION" )
fi

# create wipes the volume itself (that is what create means here), so the suite
# always runs against a database the image built from scratch.
if [ "$PULL" = 1 ]; then
  echo "== [1/4] Creating the stack from scratch, on the PUBLISHED image =="
  "$SELF_HOSTED_DIR/create.sh" -y --pull ${DB_VERSION:+"$DB_VERSION"}
else
  # The stack never builds — it only runs registry images. So package ./extension
  # into :latest HERE, then create with --no-pull so that tag survives (a plain
  # create would pull :latest from GHCR straight over the image just built).
  echo "== [1/4] Building the DB image from local source =="
  "$REPO_ROOT/docker-postgres/build.sh"
  echo "== [1/4] Creating the stack from scratch, on the locally built image =="
  "$SELF_HOSTED_DIR/create.sh" -y --no-pull
fi

echo "== [2/4] Waiting for the pg_semantius extension to install =="
# The pg_extension row appears as soon as CREATE EXTENSION runs, but the core
# schema only exists once semantius.migrate() has finished, so gate on a
# migrated `_versions` instead of on the extension row alone.
# Tolerate early connection refused / empty results while init runs.
deadline=$(( SECONDS + 180 ))
until [ "$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
      "SELECT 1 FROM pg_extension e WHERE e.extname='pg_semantius'
         AND to_regclass('public._versions') IS NOT NULL
         AND EXISTS (SELECT 1 FROM public._versions WHERE name LIKE '_core.%')" 2>/dev/null)" = "1" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting for the pg_semantius extension to install." >&2
    docker compose --project-directory "$SELF_HOSTED_DIR" logs --tail 60 postgres || true
    exit 1
  fi
  sleep 2
done
echo "Extension present."

echo "== [3/4] Deploying nwind,test (migrate skips the seeded _core) =="
( cd "$REPO_ROOT" && deno task migrate --apps nwind,test --database-url "$REST_URL" )

echo "== [4/4] Running the pgTAP suite against the extension DB =="
( cd "$REPO_ROOT" && deno task test --database-url "$REST_URL" )

echo
echo "Test complete. If all tests are green, the CREATE EXTENSION"
echo "install of _core is equivalent to the migrate install. Run the stack's"
echo "./create.sh for a clean semantius (this left the nwind,test fixtures in place)."
