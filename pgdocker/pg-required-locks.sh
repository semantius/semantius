#!/usr/bin/env bash
# pg-required-locks.sh - proves that installing a required check is safe on a live
# database, which the pgTAP suite cannot show because it runs in one session:
#   * the search for missing values takes no lock that blocks a writer;
#   * a table too busy to lock is skipped after the 2 s lock_timeout, instead of
#     queueing live traffic behind the ALTER, and a later pass picks it up.
#
# Runs against a database that has been migrated, on the plain CLI container
# (pg-cli-create.sh). It removes the entity it creates.
set -euo pipefail

CONTAINER="${CONTAINER:-postgres18-cli}"
DB="${DB:-appdb}"
FAILED=0

psqlq()   { docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc "$1" 2>&1; }
psqlrun() { docker exec "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qc "$1" >/dev/null; }
check()   { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAILED: $1 (got '$2', wanted '$3')"; FAILED=1; fi
}

cleanup() { psqlrun "DELETE FROM public.entities WHERE table_name = 'rq_lock_probe'" 2>/dev/null || true; }
trap cleanup EXIT

psqlrun "INSERT INTO public.entities (table_name, singular_label, plural_label, module_id) VALUES ('rq_lock_probe', 'Probe', 'Probes', 1);
         INSERT INTO public.fields (table_name, field_name, title, format, input_type) VALUES ('rq_lock_probe', 'v', 'V', 'text', 'required');
         INSERT INTO public.rq_lock_probe (label, v) VALUES ('one', 'x');
         ALTER TABLE public.rq_lock_probe DROP CONSTRAINT rq_lock_probe_v_assert;"

echo "The search for missing values takes no lock that blocks a writer"
MODES=$(docker exec "$CONTAINER" psql -U postgres -d "$DB" -tA -c "BEGIN;" \
  -c "SELECT dd_field_has_missing(f, 'rq_lock_probe') FROM public.fields f WHERE f.table_name = 'rq_lock_probe' AND f.field_name = 'v';" \
  -c "SELECT string_agg(DISTINCT mode, ',') FROM pg_locks WHERE pid = pg_backend_pid() AND relation = 'public.rq_lock_probe'::regclass;" \
  -c "ROLLBACK;" | grep -E 'Lock$' || true)
check "the search holds only an AccessShareLock" "$MODES" "AccessShareLock"

echo "A table too busy to lock is skipped, not queued behind"
docker exec -d "$CONTAINER" psql -U postgres -d "$DB" -c \
  "BEGIN; INSERT INTO public.rq_lock_probe (label, v) VALUES ('held', 'x'); SELECT pg_sleep(6); COMMIT;" >/dev/null
for _ in $(seq 50); do
  [ "$(psqlq "SELECT count(*) FROM pg_locks WHERE relation = 'public.rq_lock_probe'::regclass AND mode = 'RowExclusiveLock'")" = "1" ] && break
  sleep 0.1
done

START=$(date +%s)
REASON=$(psqlq "SELECT p_skipped -> 0 ->> 'reason' FROM dd_install_missing_checks('rq_lock_prob')" | tail -1)
ELAPSED=$(( $(date +%s) - START ))
case "$REASON" in
  *lock*) check "the busy table is reported as skipped" "lock" "lock" ;;
  *)      check "the busy table is reported as skipped" "$REASON" "a lock timeout" ;;
esac
if [ "$ELAPSED" -le 4 ]; then
  check "it gave up within the timeout" "yes" "yes"
else
  check "it gave up within the timeout" "${ELAPSED}s" "4s or less"
fi
check "no check was added" "$(psqlq "SELECT count(*) FROM pg_constraint WHERE conname = 'rq_lock_probe_v_assert'")" "0"

for _ in $(seq 100); do
  [ "$(psqlq "SELECT count(*) FROM public.rq_lock_probe WHERE label = 'held'")" = "1" ] && break
  sleep 0.1
done
check "the writer it found in the way finished" "$(psqlq "SELECT count(*) FROM public.rq_lock_probe WHERE label = 'held'")" "1"

echo "A later pass picks the table up"
psqlq "SELECT p_table FROM dd_install_missing_checks('rq_lock_prob')" >/dev/null
check "the check is there now" "$(psqlq "SELECT count(*) FROM pg_constraint WHERE conname = 'rq_lock_probe_v_assert'")" "1"

echo "A row already missing a value survives dump and restore"
psqlrun "ALTER TABLE public.rq_lock_probe DROP CONSTRAINT rq_lock_probe_v_assert;
         INSERT INTO public.rq_lock_probe (label, v) VALUES ('old', '');
         SELECT dd_add_required_check(f, 'rq_lock_probe') FROM public.fields f WHERE f.table_name = 'rq_lock_probe' AND f.field_name = 'v';"
RESTORE_DB=rq_lock_restore
docker exec "$CONTAINER" psql -U postgres -d postgres -qc "DROP DATABASE IF EXISTS $RESTORE_DB" -c "CREATE DATABASE $RESTORE_DB" >/dev/null
docker exec "$CONTAINER" sh -c "pg_dump -U postgres -Fc -d $DB -f /tmp/rq_lock.dump && pg_restore -U postgres -d $RESTORE_DB /tmp/rq_lock.dump" >/dev/null 2>&1 \
  && RESTORED=yes || RESTORED=no
check "the restore succeeds" "$RESTORED" "yes"
inrestore() { docker exec "$CONTAINER" psql -U postgres -d "$RESTORE_DB" -tAc "$1" 2>&1; }
check "the row is there" "$(inrestore "SELECT count(*) FROM public.rq_lock_probe WHERE label = 'old' AND v = ''")" "1"
check "the check is still NOT VALID" "$(inrestore "SELECT convalidated FROM pg_constraint WHERE conname = 'rq_lock_probe_v_assert'")" "f"
check "and it still refuses a new missing value" \
  "$(inrestore "INSERT INTO public.rq_lock_probe (label, v) VALUES ('new', '')" | grep -c 'is required')" "1"
docker exec "$CONTAINER" sh -c "rm -f /tmp/rq_lock.dump"
docker exec "$CONTAINER" psql -U postgres -d postgres -qc "DROP DATABASE $RESTORE_DB" >/dev/null

if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed."
  exit 1
fi
