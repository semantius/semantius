#!/usr/bin/env bash
# test.sh  -  Test the EXACT PostgREST deployment behavior end to end: a FRESH
# container, a FRESH data volume, and `_core` installed the real way via
# `CREATE EXTENSION pg_semantic_platform` (the whole _core install in ONE
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
# DESTRUCTIVE: wipes the stack's data volume and rebuilds it. PROMPTS for
# confirmation first (like destroy.sh); bypass with -y/--yes or ASSUME_YES=1
# / CI=true. Afterwards the stack holds the nwind,test fixtures; run
# ./create.sh for a clean semantius again.
#
# Steps:
#   0. deno task extension <ver>   regenerate the extension SQL from the CURRENT
#                     migrations so the rebuilt image bakes what you just changed
#                     (build.sh packages ./extension as-is; skip with SKIP_EXT_REGEN=1).
#   1. down -v        wipe the PostgREST stack + its data volume.
#   2. create         rebuild the semantius-db image + bring the stack up fresh;
#                     init runs CREATE EXTENSION (installs _core in ONE txn, seeds
#                     the _versions guard rows).
#   3. readiness gate poll pg_extension until the extension is present (the
#                     pg_isready healthcheck can go green before init finishes).
#   4. migrate --apps nwind,test   migrate auto-prepends _core, SKIPPED because the
#                     extension seeded _versions; only nwind,test deploy.
#   5. test           run the full pgTAP suite against the extension DB.
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"
CONTAINER="postgres18-rest"

# The DBA connection is derived from the live .env (NOT hard-coded: a checked-out
# .env may differ from .env.example).
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example."
fi
read_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"; PW="${PW:-postgres}"
PORT="$(read_env POSTGRES_PORT)";  PORT="${PORT:-5434}"
DB="$(read_env POSTGRES_DB)";      DB="${DB:-semantius}"
REST_URL="postgresql://postgres:${PW}@localhost:${PORT}/${DB}"

# Safety: this DESTROYS the running PostgREST stack + its data volume (down -v) and
# rebuilds it. Confirm before any changes — same guard as destroy.sh.
# Bypass for automation: pass -y/--yes, or set ASSUME_YES=1 or CI=true.
FORCE=0
case "${1:-}" in -y|--yes) FORCE=1 ;; esac
if [ "$FORCE" != "1" ] && [ "${ASSUME_YES:-}" != "1" ] && [ "${CI:-}" != "true" ]; then
  read -r -p "This DESTROYS the running PostgREST stack and WIPES its data volume ('${DB}', all data), then rebuilds. Continue? [y/N] " ans
  case "$ans" in
    y|Y) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

# [0/5] Regenerate the extension from CURRENT migrations, so the rebuilt image
# tests what is on disk now. Version inferred from the newest built extension SQL,
# exactly like docker-semantius/build.sh.
if [ "${SKIP_EXT_REGEN:-0}" != "1" ]; then
  VERSION="$(ls "$REPO_ROOT"/extension/pg_semantic_platform--*.sql 2>/dev/null \
    | sed -E 's/.*--([0-9.]+)\.sql/\1/' | sort -V | tail -1)"
  if [ -z "$VERSION" ]; then
    echo "Cannot infer extension version. Run 'deno task extension <ver>' once, or set SKIP_EXT_REGEN=1." >&2
    exit 1
  fi
  echo "== [0/5] Regenerating the extension SQL from current migrations (v$VERSION) =="
  ( cd "$REPO_ROOT" && deno task extension "$VERSION" )
fi

echo "== [1/5] Resetting the PostgREST stack (down -v) =="
docker compose down -v

echo "== [2/5] Rebuilding the image + bringing the stack up fresh =="
"$SCRIPT_DIR/create.sh"

echo "== [3/5] Waiting for the pg_semantic_platform extension to install =="
# Tolerate early connection refused / empty results while init runs.
deadline=$(( SECONDS + 180 ))
until [ "$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
      "SELECT 1 FROM pg_extension WHERE extname='pg_semantic_platform'" 2>/dev/null)" = "1" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting for the pg_semantic_platform extension to install." >&2
    docker compose logs --tail 60 postgres || true
    exit 1
  fi
  sleep 2
done
echo "Extension present."

echo "== [4/5] Deploying nwind,test (migrate skips the seeded _core) =="
( cd "$REPO_ROOT" && deno task migrate --apps nwind,test --database-url "$REST_URL" )

echo "== [5/5] Running the pgTAP suite against the extension DB =="
( cd "$REPO_ROOT" && deno task test --database-url "$REST_URL" )

echo
echo "Test complete. If all tests are green, the CREATE EXTENSION"
echo "install of _core is equivalent to the migrate install. Run ./create.sh"
echo "for a clean semantius (this left the nwind,test fixtures in place)."
