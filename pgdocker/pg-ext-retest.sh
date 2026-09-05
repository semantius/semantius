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
#   3b. audit-column check   entities is audited and 0270 adds
#                     entities.order_column inside the same install transaction;
#                     verify every audit row written after that point carries it.
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

# .env must exist BEFORE the first compose call, not just before the container
# is created: docker compose interpolates ${POSTGRES_PASSWORD} for every
# subcommand including `down`, and fails hard when it is unset. pg-ext-create.sh
# does this bootstrap too, but it runs in step 2 - one step too late on any
# machine without a .env, which is every CI runner.
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example."
fi

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

# The single-transaction install is the only place a column can be added to an
# already-audited table between two writes to it without a commit in between:
# entities is audited, and 0270 adds entities.order_column partway through. The
# statement-level audit trigger reads the affected rows through a transition
# table, and one cached plan in that function body serves every audited
# relation, so a row-type descriptor that failed to re-resolve would drop the new
# column from the logged record silently rather than failing. The pgTAP suite cannot see this - it runs in its
# own transaction after the install, where the descriptor is fresh.
# Rows logged before that ALTER TABLE legitimately lack the column, so the test
# is the boundary rather than the total: once any audit row carries
# order_column, every later one must carry it too. A stale descriptor shows up
# as a row without the column logged after a row with it.
echo "== [3b/5] Checking the audit record carries columns added mid-install =="
late_missing="$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
  "SELECT count(*) FROM public.audit_record_logs
    WHERE table_name = 'entities'
      AND record IS NOT NULL
      AND NOT record ? 'order_column'
      AND id > (SELECT min(id) FROM public.audit_record_logs
                 WHERE table_name = 'entities' AND record ? 'order_column')")"
if [ -z "$late_missing" ]; then
  echo "FAIL: could not read audit_record_logs; the order_column check did not run." >&2
  exit 1
fi
if [ "$late_missing" != "0" ]; then
  echo "FAIL: $late_missing audit rows for entities were logged without order_column" >&2
  echo "after earlier rows already carried it. The audit trigger reused a row-type" >&2
  echo "descriptor from before 0270." >&2
  exit 1
fi
carrying="$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
  "SELECT count(*) FROM public.audit_record_logs
    WHERE table_name = 'entities' AND record ? 'order_column'")"
if [ "$carrying" = "0" ]; then
  echo "FAIL: no audit row for entities carries order_column at all." >&2
  echo "The check above would pass vacuously; audit logging is not running." >&2
  exit 1
fi
echo "Audit records written after 0270 carry order_column ($carrying rows)."

echo "== [4/5] Deploying nwind,test (migrate skips the seeded _core) =="
( cd "$REPO_ROOT" && deno task migrate --apps nwind,test --database-url "$EXT_URL" )

echo "== [5/5] Running the pgTAP suite against the extension DB =="
( cd "$REPO_ROOT" && deno task test --database-url "$EXT_URL" "$@" )

echo
echo "Path B complete. If all tests are green, extension-_core == migrate-_core."
