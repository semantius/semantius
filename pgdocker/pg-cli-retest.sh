#!/usr/bin/env bash
# pg-cli-retest.sh  -  Path A harness: deploy `_core,cloud,test,nwind` via the CLI
# migrate path onto the plain CLI-testing container, then run the pgTAP suite.
# The mirror of pg-ext-retest.sh (which installs `_core` via CREATE EXTENSION).
#
# Fully non-interactive. Steps:
#   1. pg-cli-create  fresh plain PG18 container on 5432 (no extension).
#   2. readiness gate poll until the DBA login accepts connections.
#   3. retest --confirm --env pgdocker
#                     dropall -> migrate _core,cloud,test,nwind -> test.
#
# `retest`/`reset` are deliberately unchanged; this only wraps them. The DBA
# connection comes from .env.pgdocker (port 5432, password must match
# pgdocker/.env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

CONTAINER="postgres18-cli"

echo "== [1/3] Creating a fresh CLI-testing container =="
./pg-cli-create.sh

# `|| true` so a missing key (grep exits 1) does not trip `set -o pipefail`.
DB="$(grep -E '^POSTGRES_DB=' .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true)"; DB="${DB:-appdb}"

echo "== [2/3] Waiting for the DBA login to accept connections =="
# The healthcheck can pass before 10-roles.sql finishes; poll pg_isready.
deadline=$(( SECONDS + 180 ))
until docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d "$DB" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting for PostgreSQL to accept connections." >&2
    docker compose logs --tail 60 || true
    exit 1
  fi
  sleep 2
done
echo "PostgreSQL ready."

echo "== [3/3] retest (dropall -> migrate _core,cloud,test,nwind -> test) =="
( cd "$REPO_ROOT" && deno task retest --confirm --env pgdocker )

echo
echo "Path A complete. If all tests are green, the migrate path is good."
