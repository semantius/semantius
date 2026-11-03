#!/usr/bin/env bash
# pg-rollup-race.sh - proves that overlapping child writes all reach a rollup, which
# the pgTAP suite cannot show because it runs in one session:
#   * two inserts under one parent both count, whether or not they add the same amount;
#   * a lower value inserted while the maximum is being deleted becomes the maximum.
#
# Runs against a database that has been migrated, on the plain CLI container
# (pg-cli-create.sh). It removes the entities it creates.
set -euo pipefail

CONTAINER="${CONTAINER:-postgres18-cli}"
DB="${DB:-appdb}"
FAILED=0

psqlq()   { docker exec "$CONTAINER" psql -U postgres -d "$DB" -qtAc "$1" 2>&1; }
psqlrun() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qc "$1" >/dev/null; }
check()   { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAILED: $1 (got '$2', wanted '$3')"; FAILED=1; fi
}

cleanup() {
  psqlrun "DELETE FROM public.fields WHERE (table_name = 'race_parents' AND field_name IN ('total', 'line_count')) OR (table_name = 'race_peaks' AND field_name = 'top')" 2>/dev/null || true
  psqlrun "DELETE FROM public.entities WHERE table_name IN ('race_lines', 'race_peak_lines')" 2>/dev/null || true
  psqlrun "DELETE FROM public.entities WHERE table_name IN ('race_parents', 'race_peaks')" 2>/dev/null || true
}
trap cleanup EXIT

psqlrun "INSERT INTO public.entities (table_name, singular_label, plural_label, module_id)
         VALUES ('race_parents', 'Parent', 'Parents', 1), ('race_lines', 'Line', 'Lines', 1),
                ('race_peaks', 'Peak', 'Peaks', 1), ('race_peak_lines', 'Peak line', 'Peak lines', 1);
         INSERT INTO public.fields (table_name, field_name, title, format, reference_table, reference_delete_mode)
         VALUES ('race_lines', 'parent_id', 'Parent', 'reference', 'race_parents', 'restrict'),
                ('race_lines', 'amount', 'Amount', 'number', '', ''),
                ('race_peak_lines', 'peak_id', 'Peak', 'reference', 'race_peaks', 'restrict'),
                ('race_peak_lines', 'amount', 'Amount', 'number', '', '');"
psqlrun "INSERT INTO public.fields (table_name, field_name, title, format, rollup) VALUES
         ('race_parents', 'total', 'Total', 'number', '{\"link_field\": \"race_lines.parent_id\", \"function\": \"sum\", \"value_field\": \"amount\"}'),
         ('race_parents', 'line_count', 'Lines', 'int64', '{\"link_field\": \"race_lines.parent_id\", \"function\": \"count\"}'),
         ('race_peaks', 'top', 'Top', 'number', '{\"link_field\": \"race_peak_lines.peak_id\", \"function\": \"max\", \"value_field\": \"amount\"}');"

new_parent() { psqlq "INSERT INTO public.race_parents (label) VALUES ('p') RETURNING id"; }

is_true() { [ "$(psqlq "$1")" = "t" ]; }
wait_for() { # wait_for <description> <command...>: runs the command until it succeeds
  local what=$1
  shift
  for _ in $(seq 100); do
    "$@" && return
    sleep 0.1
  done
  echo "  FAILED: timed out waiting for $what"
  exit 1
}
second_settled() { # second_settled <pid>: the second writer has finished or waits for a lock
  ! kill -0 "$1" 2>/dev/null || is_true "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'race_second' AND wait_event_type = 'Lock')"
}

# overlap <first statement> <second statement>: runs the second while the first is
# uncommitted. A hold of a fixed length does not guarantee that: on a slow machine the
# second writer starts after the hold ended, runs alone, and the check passes on code that
# has the race. So the first session reads from a pipe, and commits only once the second
# has finished or is waiting for a lock.
overlap() {
  exec 3> >(docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -q >/dev/null)
  echo "BEGIN; $1; SET LOCAL application_name = 'race_first';" >&3
  wait_for "the first writer's statement" is_true "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'race_first')"
  docker exec -e PGAPPNAME=race_second -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qc "$2" >/dev/null &
  local second=$!
  wait_for "the second writer" second_settled "$second"
  echo "COMMIT;" >&3
  exec 3>&-
  wait "$second"
  wait_for "the first writer's commit" is_true "SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'race_first')"
}

stored() { psqlq "SELECT round(total)::int || ' / ' || line_count FROM public.race_parents WHERE id = $1"; }
actual() { psqlq "SELECT round(sum(amount))::int || ' / ' || count(*) FROM public.race_lines WHERE parent_id = $1"; }

echo "Two inserts under one parent both count (total / count)"
for amounts in "5 7" "5 5"; do
  set -- $amounts
  parent=$(new_parent)
  overlap "INSERT INTO public.race_lines (label, parent_id, amount) VALUES ('l', $parent, $1)" \
          "INSERT INTO public.race_lines (label, parent_id, amount) VALUES ('l', $parent, $2)"
  check "amounts $1 and $2" "$(stored "$parent")" "$(actual "$parent")"
done

# The max has a link of its own because a sum or a count beside it moves on every insert:
# the insert would then reach the parent row and the guard would correct the max, with or
# without the lock. Alone, the insert computes the max it can see, 10, finds it unchanged,
# and without the lock leaves the row to the delete, which cannot see the 3.
echo "A lower value inserted while the maximum is deleted becomes the maximum"
peak=$(psqlq "INSERT INTO public.race_peaks (label) VALUES ('p') RETURNING id")
psqlrun "INSERT INTO public.race_peak_lines (label, peak_id, amount) VALUES ('l', $peak, 10), ('l', $peak, 1)"
overlap "DELETE FROM public.race_peak_lines WHERE peak_id = $peak AND amount = 10" \
        "INSERT INTO public.race_peak_lines (label, peak_id, amount) VALUES ('l', $peak, 3)"
check "delete 10, insert 3" "$(psqlq "SELECT round(top)::int FROM public.race_peaks WHERE id = $peak")" "3"

exit "$FAILED"
