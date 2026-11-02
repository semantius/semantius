#!/usr/bin/env bash
# pg-reference-delete-race.sh - proves that a field being written and the entity it
# points at being deleted cannot both succeed, which the pgTAP suite cannot show
# because it runs in one session. delete_dd_table cannot see a field that has not
# committed, so without the row lock validate_reference_table takes, the delete would
# pass its check and leave the new field pointing at nothing:
#   * a delete arriving while the field is uncommitted waits, then is refused (90260);
#   * a field arriving while the delete is uncommitted waits, then is refused (90212).
# On a managed entity the foreign key the field creates also stops the second case,
# so it runs on an unmanaged entity too, where the lock is all there is.
#
# Runs against a database that has been migrated, on the plain CLI container
# (pg-cli-create.sh). It removes the entities it creates.
set -euo pipefail

CONTAINER="${CONTAINER:-postgres18-cli}"
DB="${DB:-appdb}"
FAILED=0

ADD_FIELD="INSERT INTO public.fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
           VALUES ('rr_customers', 'region', 'Region', 'reference', 'rr_regions', 'restrict')"
ADD_UNMANAGED_FIELD="INSERT INTO public.fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
           VALUES ('rr_unmanaged', 'region', 'Region', 'reference', 'rr_regions', 'restrict')"
DELETE_ENTITY="DELETE FROM public.entities WHERE table_name = 'rr_regions'"

psqlq()   { docker exec "$CONTAINER" psql -U postgres -d "$DB" -tAc "$1" 2>&1; }
psqlrun() { docker exec "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qc "$1" >/dev/null; }
check()   { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAILED: $1 (got '$2', wanted '$3')"; FAILED=1; fi
}

# The SQLSTATE a statement fails with, or nothing when it succeeds.
sqlstate_of() {
  docker exec "$CONTAINER" psql -U postgres -d "$DB" -v VERBOSITY=verbose -qc "$1" 2>&1 \
    | sed -n 's/^ERROR: *\([0-9A-Z]\{5\}\):.*/\1/p' || true
}

# Starts a transaction in a second session that does $1, then stays open for 3 s.
hold_open() {
  docker exec -d "$CONTAINER" psql -U postgres -d "$DB" -c "BEGIN; $1; SELECT pg_sleep(3); COMMIT;" >/dev/null
  for _ in $(seq 100); do
    [ "$(psqlq "SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'PgSleep'")" = "1" ] && return
    sleep 0.1
  done
  echo "  FAILED: the second session never got to its sleep"
  FAILED=1
}

# The field has to go first: its entity cannot be deleted while it exists.
cleanup() {
  psqlrun "DELETE FROM public.fields WHERE table_name IN ('rr_customers', 'rr_unmanaged') AND field_name = 'region';
           DELETE FROM public.entities WHERE table_name IN ('rr_customers', 'rr_unmanaged', 'rr_regions');" 2>/dev/null || true
}
trap cleanup EXIT

# Fresh entities for each scenario, so that one going wrong cannot make the next pass.
setup() {
  cleanup
  psqlrun "INSERT INTO public.entities (table_name, singular_label, plural_label, module_id, managed) VALUES
             ('rr_regions',   'Region',    'Regions',    1, TRUE),
             ('rr_customers', 'Customer',  'Customers',  1, TRUE),
             ('rr_unmanaged', 'Unmanaged', 'Unmanaged',  1, FALSE);"
}

# A statement that did not wait takes well under 2 s, even with docker exec in front of it.
check_waited() { # check_waited <description> <seconds>
  if [ "$2" -ge 2 ]; then check "$1" "yes" "yes"; else check "$1" "${2}s" "2s or more"; fi
}

echo "A delete arriving while the field is uncommitted waits, then is refused"
setup
hold_open "$ADD_FIELD"
START=$(date +%s)
STATE=$(sqlstate_of "$DELETE_ENTITY")
ELAPSED=$(( $(date +%s) - START ))
check "the delete is refused with 90260" "$STATE" "90260"
check_waited "it waited for the field to commit" "$ELAPSED"
check "the entity is still there" "$(psqlq "SELECT count(*) FROM public.entities WHERE table_name = 'rr_regions'")" "1"
check "the field has its foreign key" "$(psqlq "SELECT count(*) FROM pg_constraint WHERE conname = 'rr_customers_region_fkey'")" "1"

echo "A field arriving while the delete is uncommitted waits, then is refused"
setup
hold_open "$DELETE_ENTITY"
START=$(date +%s)
STATE=$(sqlstate_of "$ADD_FIELD")
ELAPSED=$(( $(date +%s) - START ))
check "the field is refused with 90212" "$STATE" "90212"
check_waited "it waited for the delete to commit" "$ELAPSED"
check "the entity is gone" "$(psqlq "SELECT count(*) FROM public.entities WHERE table_name = 'rr_regions'")" "0"
check "no field row was left" "$(psqlq "SELECT count(*) FROM public.fields WHERE table_name = 'rr_customers' AND field_name = 'region'")" "0"

echo "The same on an unmanaged entity, which creates no foreign key to stop it"
setup
hold_open "$DELETE_ENTITY"
START=$(date +%s)
STATE=$(sqlstate_of "$ADD_UNMANAGED_FIELD")
ELAPSED=$(( $(date +%s) - START ))
check "the field is refused with 90212" "$STATE" "90212"
check_waited "it waited for the delete to commit" "$ELAPSED"
check "no field row was left" "$(psqlq "SELECT count(*) FROM public.fields WHERE table_name = 'rr_unmanaged' AND field_name = 'region'")" "0"

if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks failed."
  exit 1
fi
