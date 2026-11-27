#!/usr/bin/env bash
# pg-attach-race.sh - proves what the pgTAP suite cannot show because it runs in
# one session (0450_attachables.sql):
#   * an attach and a delete of its target cannot leave an attachment without
#     its target. The attach step (common.attach_target) locks the target row
#     FOR KEY SHARE: a delete of the target waits until the attach has
#     committed, and its delete step then finds the attachment and cascades or
#     refuses as attach_on_target_delete says; an attach that waits for a
#     delete finds no row to lock once the delete commits, and is refused.
#   * two deletes that each remove one of a multiple record's last two links
#     both go through, and the record stays, without links.
#   * a change of the attach mode waits for an insert under the old mode
#     (check_entity_attach locks the table), and a switch-off of a target
#     waits for an attach to it (the attach step locks the row of
#     entity_attachables), and both then see the record and refuse.
#   * a change of the attach mode does not deadlock with a transaction that
#     removes a record's links and then the record.
# Correct at READ COMMITTED, the default and PostgREST's level.
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
  psqlrun "DELETE FROM public.race_notes; DELETE FROM public.race_pins; DELETE FROM public.race_todos; DELETE FROM public.race_memos" 2>/dev/null || true
  psqlrun "DELETE FROM public.entity_attachables WHERE attachable IN ('race_notes', 'race_pins', 'race_todos', 'race_memos')" 2>/dev/null || true
  psqlrun "DELETE FROM public.entities WHERE table_name IN ('race_notes', 'race_pins', 'race_todos', 'race_memos')" 2>/dev/null || true
  psqlrun "DELETE FROM public.entities WHERE table_name = 'race_targets'" 2>/dev/null || true
}
trap cleanup EXIT

psqlrun "INSERT INTO public.entities (table_name, singular_label, plural_label, module_id)
         VALUES ('race_targets', 'Target', 'Targets', 1);
         INSERT INTO public.entities (table_name, singular_label, plural_label, module_id,
                                      attach_mode, attach_permission, attach_on_target_delete)
         VALUES ('race_notes', 'Note', 'Notes', 1, 'single', 'view', 'cascade'),
                ('race_pins', 'Pin', 'Pins', 1, 'single', 'view', 'restrict'),
                ('race_todos', 'Todo', 'Todos', 1, 'multiple', 'view', ''),
                ('race_memos', 'Memo', 'Memos', 1, 'single', 'view', 'cascade');
         INSERT INTO public.entity_attachables (target, attachable)
         VALUES ('race_targets', 'race_notes'), ('race_targets', 'race_pins'), ('race_targets', 'race_todos'),
                ('race_targets', 'race_memos');"

new_target() { psqlq "INSERT INTO public.race_targets (label) VALUES ('t') RETURNING id"; }
new_todo()   { psqlq "INSERT INTO public.race_todos (label) VALUES ('d') RETURNING id"; }
link()       { psqlrun "INSERT INTO public.race_todos_links (race_todos_id, attached_to) VALUES ($1, 'race_targets:$2')"; }

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
# uncommitted, and commits the first only once the second has finished or waits for
# a lock, as pg-rollup-race.sh does. The second's outcome is left in SECOND_RESULT:
# ok, or the SQLSTATE it failed with.
overlap() {
  exec 3> >(docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -q >/dev/null)
  echo "BEGIN; $1; SET LOCAL application_name = 'race_first';" >&3
  wait_for "the first writer's statement" is_true "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'race_first')"
  local out
  out=$(mktemp)
  ( docker exec -e PGAPPNAME=race_second -e PGOPTIONS='-c client_min_messages=warning' \
      "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -qc "$2" >/dev/null 2>"$out" ) &
  local second=$!
  wait_for "the second writer" second_settled "$second"
  echo "COMMIT;" >&3
  exec 3>&-
  if wait "$second"; then SECOND_RESULT=ok; else SECOND_RESULT=$(grep -oE 'ERROR:  [0-9A-Z]{5}' "$out" | head -1 | cut -c9-); fi
  rm -f "$out"
  wait_for "the first writer's commit" is_true "SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'race_first')"
}

echo "A delete that waits for an attach to its target cascades to the attachment"
target=$(new_target)
overlap "INSERT INTO public.race_notes (label, attached_to) VALUES ('n', 'race_targets:$target')" \
        "DELETE FROM public.race_targets WHERE id = $target"
check "the delete went through" "$SECOND_RESULT" "ok"
check "no note is left without its target" \
      "$(psqlq "SELECT count(*) FROM public.race_notes WHERE attached_to = 'race_targets:$target'")" "0"

echo "A delete that waits for an attach to its target refuses it under restrict"
target=$(new_target)
overlap "INSERT INTO public.race_pins (label, attached_to) VALUES ('p', 'race_targets:$target')" \
        "DELETE FROM public.race_targets WHERE id = $target"
check "the delete is refused (91016)" "$SECOND_RESULT" "91016"
check "the target and its pin are both there" \
      "$(psqlq "SELECT count(*) FROM public.race_targets t JOIN public.race_pins p ON p.attached_to = 'race_targets:' || t.id WHERE t.id = $target")" "1"

echo "An attach that waits for a delete of its target is refused"
target=$(new_target)
overlap "DELETE FROM public.race_targets WHERE id = $target"         "INSERT INTO public.race_notes (label, attached_to) VALUES ('n', 'race_targets:$target')"
check "the attach is refused (91018)" "$SECOND_RESULT" "91018"
check "no note names the deleted target"       "$(psqlq "SELECT count(*) FROM public.race_notes WHERE attached_to = 'race_targets:$target'")" "0"

echo "A link that waits for a delete of its target is refused"
target=$(new_target)
todo=$(new_todo)
overlap "DELETE FROM public.race_targets WHERE id = $target"         "INSERT INTO public.race_todos_links (race_todos_id, attached_to) VALUES ($todo, 'race_targets:$target')"
check "the link is refused (91018)" "$SECOND_RESULT" "91018"
check "no link names the deleted target"       "$(psqlq "SELECT count(*) FROM public.race_todos_links WHERE attached_to = 'race_targets:$target'")" "0"

echo "Two deletes that each remove one of a record's last two links leave the record without links"
target_a=$(new_target)
target_b=$(new_target)
todo=$(new_todo)
link "$todo" "$target_a"
link "$todo" "$target_b"
overlap "DELETE FROM public.race_targets WHERE id = $target_a"         "DELETE FROM public.race_targets WHERE id = $target_b"
check "the second delete went through" "$SECOND_RESULT" "ok"
check "the todo that lost both links stays, without links" \
      "$(psqlq "SELECT count(*) || '/' || (SELECT count(*) FROM public.race_todos_links WHERE race_todos_id = $todo) FROM public.race_todos WHERE id = $todo")" "1/0"

echo "A change of the attach mode waits for an insert under the old mode, and is refused"
target=$(new_target)
overlap "INSERT INTO public.race_notes (label, attached_to) VALUES ('n', 'race_targets:$target')"         "UPDATE public.entities SET attach_mode = 'multiple' WHERE table_name = 'race_notes'"
check "the mode change is refused (91005)" "$SECOND_RESULT" "91005"
check "the note keeps its target"       "$(psqlq "SELECT count(*) FROM public.race_notes WHERE attached_to = 'race_targets:$target'")" "1"

echo "Switching a target off waits for an attach to it, and is refused"
target=$(new_target)
overlap "INSERT INTO public.race_memos (label, attached_to) VALUES ('m', 'race_targets:$target')"         "DELETE FROM public.entity_attachables WHERE target = 'race_targets' AND attachable = 'race_memos'"
check "the switch-off is refused (91015)" "$SECOND_RESULT" "91015"
check "the memo and the row that admits it are both there"       "$(psqlq "SELECT count(*) FROM public.race_memos m, public.entity_attachables ea WHERE m.attached_to = 'race_targets:$target' AND ea.target = 'race_targets' AND ea.attachable = 'race_memos'")" "1"

echo "A change of the attach mode does not deadlock with links and a record being deleted"
target=$(new_target)
todo=$(new_todo)
link "$todo" "$target"
out=$(mktemp)
# The links first, then the record.
( docker exec -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -X -qtA \
    -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
    -c "BEGIN" -c "DELETE FROM public.race_todos_links WHERE race_todos_id = $todo" -c "SELECT pg_sleep(2)" \
    -c "DELETE FROM public.race_todos WHERE id = $todo" -c "COMMIT" >/dev/null 2>"$out" ) &
first=$!
sleep 1
MODE_RESULT=$(docker exec -e PGOPTIONS='-c client_min_messages=warning' "$CONTAINER" psql -U postgres -d "$DB" -X -qtA \
    -v VERBOSITY=verbose -c "UPDATE public.entities SET attach_mode = 'none' WHERE table_name = 'race_todos'" 2>&1 >/dev/null \
    | grep -oE 'ERROR:  [0-9A-Z]{5}' | head -1 | cut -c9- || true)
if wait "$first"; then DELETE_RESULT=ok; else DELETE_RESULT=$(grep -oE 'ERROR:  [0-9A-Z]{5}' "$out" | head -1 | cut -c9- || true); fi
rm -f "$out"
check "the mode change is refused, not deadlocked (91005)" "${MODE_RESULT:-ok}" "91005"
check "the links and the record are deleted" "$DELETE_RESULT" "ok"

exit "$FAILED"
