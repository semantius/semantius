#!/usr/bin/env bash
# pg-rest-retest.sh  -  Retest the ALREADY-RUNNING pgrest database IN PLACE.
# Thin wrapper around the CLI `retest` (dropall -> migrate --apps test,nwind ->
# test) pointed at this stack's appdb over its fixed connection string — the same
# in-place reset used on hosted Postgres (e.g. Neon) where you cannot drop and
# recreate the database/container.
#
# Extra args are forwarded to `deno task retest` (e.g. --confirm to skip the
# prompt, --failfast). The CLI prompts for confirmation unless --confirm is passed.
#
# NOTE: on the pgrest stack `_core` is installed via CREATE EXTENSION, so dropall
# leaves the extension-owned `_core` in place and only resets the test/nwind
# objects. To fully rebuild and reinstall `_core` the real way (fresh container +
# CREATE EXTENSION), use ./pg-rest-test.sh.
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd .. && pwd)"
CONTAINER="postgres18-rest"

if [ ! -f .env ]; then
  echo ".env not found in $(pwd) — run ./pg-rest-create.sh first." >&2
  exit 1
fi
read_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"; PW="${PW:-postgres}"
PORT="$(read_env POSTGRES_PORT)";  PORT="${PORT:-5434}"
DB="$(read_env POSTGRES_DB)";      DB="${DB:-appdb}"
REST_URL="postgresql://postgres:${PW}@localhost:${PORT}/${DB}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container '$CONTAINER' is not running." >&2
  echo "Start the stack first:  ./pg-rest-create.sh   (or ./pg-rest-start.sh)" >&2
  exit 1
fi

echo "== Retesting '${DB}' in place via 'deno task retest' =="
( cd "$REPO_ROOT" && deno task retest --database-url "$REST_URL" "$@" )
