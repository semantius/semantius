#!/usr/bin/env bash
# pg-ext-dump-restore.sh  -  Path B round trip: a pg_dump of the
# extension-installed database restores completely into a second database
# (release review items B1 and B3).
#
# Runs against the extension container as pg-ext-retest.sh leaves it
# (pg_semantius installed, nwind,test deployed: that is the sample data).
# Steps:
#   1. snapshot  the source database: row count of every member table that is
#                registered for pg_dump, last_value/is_called of every
#                registered sequence, row count of every dictionary table
#                (nwind's tables are not members and dump normally) and of
#                every user queue, plus the extension version.
#   2. dump      pg_dump -Fc inside the container.
#   3. restore   into a fresh database on the same cluster, the way the
#                extension README documents it: --section=pre-data, then
#                --data-only --disable-triggers, then --section=post-data,
#                each with --exit-on-error and with
#                PGOPTIONS='-c pg_semantius.skip_audit=on'.
#   4. compare   the same snapshot of the restored database must be identical.
#   5. suite     with --suite, run the pgTAP suite against the restored database.
#
# Non-interactive and re-runnable. The restored database is dropped at the end
# unless --keep is given. Exits 1 on a restore error or any difference.
set -euo pipefail

# Git Bash on Windows rewrites arguments that look like POSIX paths (the dump
# file path inside the container) into Windows paths; switch that off here.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

CONTAINER="postgres18-ext"
RESTORE_DB="appdb_restore"
DUMP_FILE="/tmp/pg_semantius_roundtrip.dump"
RUN_SUITE=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --suite) RUN_SUITE=1 ;;
    --keep) KEEP=1 ;;
    *) echo "Unknown argument: $arg (use --suite and/or --keep)" >&2; exit 2 ;;
  esac
done

# Same .env handling as pg-ext-retest.sh: never assume the password.
read_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"
DB="$(read_env POSTGRES_DB)"; DB="${DB:-appdb}"
PORT="$(read_env POSTGRES_EXT_PORT)"; PORT="${PORT:-5433}"
if [ -z "$PW" ]; then
  echo "POSTGRES_PASSWORD not found in $SCRIPT_DIR/.env" >&2
  exit 1
fi

if [ "$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc \
      "SELECT 1 FROM pg_extension WHERE extname='pg_semantius'" 2>/dev/null)" != "1" ]; then
  echo "The pg_semantius extension is not installed in $CONTAINER/$DB. Run ./pg-ext-retest.sh first." >&2
  exit 1
fi

psql_db() { docker exec -i "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -tA -F $'\t' -d "$1"; }

# One row per compared value: kind, name, value. Registered member tables are
# read from pg_extension.extconfig so a table added to the registry is compared
# automatically. Row counts of the dictionary tables cover the orphan case (a
# physical table that came back without its entities/fields rows). The
# transient raci_notify queue is not compared (not dumped by design).
SNAPSHOT_SQL=$(cat <<'SQL'
WITH cfg AS (
    SELECT n.nspname || '.' || quote_ident(c.relname) AS rel, c.relkind
      FROM pg_extension e
      CROSS JOIN LATERAL unnest(e.extconfig) AS x(relid)
      JOIN pg_class c ON c.oid = x.relid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE e.extname = 'pg_semantius'
),
snapshot AS (
    SELECT 'table' AS kind, rel AS name,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %s', rel), false, true, '')))[1]::text AS value
      FROM cfg WHERE relkind IN ('r', 'p')
    UNION ALL
    SELECT 'sequence', rel,
           (xpath('/row/c/text()', query_to_xml(format('SELECT last_value::text || '','' || is_called::text AS c FROM %s', rel), false, true, '')))[1]::text
      FROM cfg WHERE relkind = 'S'
    UNION ALL
    SELECT 'entity', table_name,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
      FROM public.entities
    UNION ALL
    SELECT 'queue', queue_name,
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM pgmq.%I', 'q_' || queue_name), false, true, '')))[1]::text
      FROM pgmq.meta WHERE queue_name <> 'raci_notify'
    UNION ALL
    SELECT 'extension', extname, extversion FROM pg_extension WHERE extname = 'pg_semantius'
)
SELECT kind, name, value FROM snapshot ORDER BY kind, name;
SQL
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== [1/5] Snapshot of the source database ($DB) =="
printf '%s\n' "$SNAPSHOT_SQL" | psql_db "$DB" > "$WORK/source.tsv"
echo "$(wc -l < "$WORK/source.tsv") values captured."

echo "== [2/5] pg_dump -Fc =="
docker exec "$CONTAINER" pg_dump -U postgres -d "$DB" -Fc -f "$DUMP_FILE"
docker exec "$CONTAINER" ls -l "$DUMP_FILE"

echo "== [3/5] Three-pass restore into $RESTORE_DB =="
docker exec "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $RESTORE_DB WITH (FORCE)" \
  -c "CREATE DATABASE $RESTORE_DB"
restore() {
  docker exec -e PGOPTIONS='-c pg_semantius.skip_audit=on' "$CONTAINER" \
    pg_restore -U postgres -d "$RESTORE_DB" --exit-on-error "$@" "$DUMP_FILE"
}
echo "-- pre-data (CREATE EXTENSION, tables, functions)"
restore --section=pre-data
echo "-- data (rows and sequences, triggers disabled)"
restore --data-only --disable-triggers
echo "-- post-data (indexes, constraints, triggers, policies)"
restore --section=post-data

echo "== [4/5] Snapshot of the restored database and comparison =="
printf '%s\n' "$SNAPSHOT_SQL" | psql_db "$RESTORE_DB" > "$WORK/restored.tsv"
if diff -u "$WORK/source.tsv" "$WORK/restored.tsv" > "$WORK/diff.txt"; then
  echo "Identical: $(wc -l < "$WORK/source.tsv") values (tables, sequences, dictionary tables, queues, extension version)."
else
  echo "DIFFERENCES between $DB and $RESTORE_DB:" >&2
  cat "$WORK/diff.txt" >&2
  exit 1
fi

if [ "$RUN_SUITE" = "1" ]; then
  echo "== [5/5] pgTAP suite against $RESTORE_DB =="
  ( cd "$REPO_ROOT" && deno task test --database-url "postgresql://postgres:${PW}@localhost:${PORT}/${RESTORE_DB}" )
else
  echo "== [5/5] Suite skipped (pass --suite to run the pgTAP suite against the restored database) =="
fi

if [ "$KEEP" = "1" ]; then
  echo "Kept $RESTORE_DB (postgresql://postgres:<POSTGRES_PASSWORD>@localhost:${PORT}/${RESTORE_DB})."
else
  docker exec "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $RESTORE_DB WITH (FORCE)" > /dev/null
  docker exec "$CONTAINER" rm -f "$DUMP_FILE"
fi

echo
echo "Round trip complete: the dump of the extension-installed database restores without loss."
