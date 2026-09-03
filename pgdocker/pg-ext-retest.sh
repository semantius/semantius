#!/usr/bin/env bash
# pg-ext-retest.sh  -  Path B harness: prove the extension-installed `_core` is
# equivalent to the migrate-installed `_core` by running the SAME pgTAP suite on
# top of an EXTENSION install.
#
# Fully non-interactive. Steps:
#   1. down -v        reset the ext stack (wipe the data volume). NOT
#                     pg-ext-delete, which prompts interactively and would hang.
#   2. pg-ext-create  fresh ext container; `CREATE EXTENSION pg_semantius` installs
#                     `_core` and creates + seeds the `_versions` guard rows.
#   3. readiness gate poll until the `pg_semantius` extension is present (the
#                     pg_isready healthcheck can go green before the init scripts
#                     finish, so we check pg_extension directly).
#   4. migrate --apps nwind,test   migrate auto-prepends `_core`, which is
#                     SKIPPED because the extension seeded `_versions`; only
#                     `test`,`nwind` are deployed onto the extension's `_core`.
#                     (The extension's `_core` already includes the
#                     `webhook_receivers`/`dashboards` tables that test.0030_seed
#                     and several test files depend on.)
#   5. test           run the full pgTAP suite against the ext DB.
#
# Extra arguments are forwarded to `deno task test`, so `./pg-ext-retest.sh --coverage`
# is the extension-install + suite + coverage loop (see ../README.md).
#
# Re-runnable. The DBA connection is derived from pgdocker/.env (NOT hard-coded:
# an existing .env may differ from .env.example) and passed via --database-url,
# which also takes priority over any exported DATABASE_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.ext.yml"
PROJECT="semantius-ext"
CONTAINER="postgres18-ext"

echo "== [1/5] Resetting the extension stack (down -v) =="
docker compose -f "$COMPOSE_FILE" -p "$PROJECT" down -v

echo "== [2/5] Creating a fresh extension container =="
./pg-ext-create.sh

# Derive the DBA connection from the live .env (created by pg-ext-create if it
# was missing). Do NOT assume `postgres`: the checked-out .env uses `devpassword`.
# `|| true` so a missing key (grep exits 1) does not trip `set -o pipefail`.
read_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"
DB="$(read_env POSTGRES_DB)"; DB="${DB:-appdb}"
PORT="$(read_env POSTGRES_EXT_PORT)"; PORT="${PORT:-5433}"
if [ -z "$PW" ]; then
  echo "POSTGRES_PASSWORD not found in $SCRIPT_DIR/.env" >&2
  exit 1
fi
EXT_URL="postgresql://postgres:${PW}@localhost:${PORT}/${DB}"

echo "== [3/5] Waiting for the pg_semantius extension to install =="
# The pg_extension row appears as soon as CREATE EXTENSION runs, but the core
# schema only exists once semantius.migrate() has finished, so gate on a
# migrated `_versions` instead of on the extension row alone.
# Tolerate early "connection refused"/empty results: the healthcheck can pass
# before 10-roles.sql / 20-extension.sql have finished.
deadline=$(( SECONDS + 180 ))
until [ "$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
      "SELECT 1 FROM pg_extension e WHERE e.extname='pg_semantius'
         AND to_regclass('public._versions') IS NOT NULL
         AND EXISTS (SELECT 1 FROM public._versions WHERE name LIKE '_core.%')" 2>/dev/null)" = "1" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting for the pg_semantius extension to install." >&2
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT" logs --tail 60 || true
    exit 1
  fi
  sleep 2
done
echo "Extension present."

echo "== [4/5] Deploying nwind,test (migrate skips the seeded _core) =="
( cd "$REPO_ROOT" && deno task migrate --apps nwind,test --database-url "$EXT_URL" )

echo "== [5/5] Running the pgTAP suite against the extension DB =="
( cd "$REPO_ROOT" && deno task test --database-url "$EXT_URL" "$@" )

echo
echo "Path B complete. If all tests are green, extension-_core == migrate-_core."
