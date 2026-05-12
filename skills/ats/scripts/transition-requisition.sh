#!/usr/bin/env bash
# transition-requisition.sh: Move one job_openings row to a target status,
# pairing opened_at on the first non-draft transition and filled_at on
# `filled`. The platform enforces non_draft_requires_opened_at and
# filled_status_requires_filled_at; the script pairs both in one PATCH so
# the write lands clean. opened_before_filled and opened_before_target_start
# are pre-existing date-ordering rules; if the live row's existing dates
# break the ordering, the platform throws and the script surfaces verbatim.
#
# Usage: transition-requisition.sh <job-code> <draft|open|on_hold|filled|closed|cancelled>
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / invalid status
#        2 on platform error
#
# Idempotent: re-running with the same target status is a no-op (status
# check at step 2 short-circuits).
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $(basename "$0") <job-code> <draft|open|on_hold|filled|closed|cancelled>" >&2
  exit 1
fi

job_code="$1"
target="$2"

case "$target" in draft|open|on_hold|filled|closed|cancelled) ;; *) echo "step 0: target status must be one of draft, open, on_hold, filled, closed, cancelled" >&2; exit 1 ;; esac

# Step 1: resolve job opening.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_code}&select=id,status,opened_at,filled_at\"}") \
  || { echo "step 1: job opening '${job_code}' not found" >&2; exit 1; }
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
current_status=$(printf '%s' "$job_opening" | grep -oE '"status":"[^"]+"' | sed 's/"status":"\([^"]*\)"/\1/')
existing_opened=$(printf '%s' "$job_opening" | grep -oE '"opened_at":"[^"]+"' | head -n1 | sed 's/"opened_at":"\([^"]*\)"/\1/' || true)

# Step 2: short-circuit no-op.
if [ "$current_status" = "$target" ]; then
  echo "transition-requisition: ${job_code} already at status=${target}; nothing to do" >&2
  exit 0
fi

today=$(date -u +"%Y-%m-%d")

# Step 3: compose paired body.
case "$target" in
  draft)
    body="{\"status\":\"draft\"}"
    ;;
  open|on_hold|closed|cancelled)
    # Pair opened_at only on the first non-draft transition.
    if [ -z "$existing_opened" ] || [ "$existing_opened" = "null" ]; then
      body="{\"status\":\"${target}\",\"opened_at\":\"${today}\"}"
    else
      body="{\"status\":\"${target}\"}"
    fi
    ;;
  filled)
    # Pair filled_at always; pair opened_at if missing.
    if [ -z "$existing_opened" ] || [ "$existing_opened" = "null" ]; then
      body="{\"status\":\"filled\",\"opened_at\":\"${today}\",\"filled_at\":\"${today}\"}"
    else
      body="{\"status\":\"filled\",\"filled_at\":\"${today}\"}"
    fi
    ;;
esac

# Step 4: PATCH.
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_openings?id=eq.${job_opening_id}\",\"body\":${body}}" \
  > /dev/null \
  || { echo "step 4: PATCH failed; surface platform code verbatim (non_draft_requires_opened_at, filled_status_requires_filled_at, opened_before_filled, opened_before_target_start)" >&2; exit 2; }

echo "transition-requisition: ok (${job_code} ${current_status} -> ${target})"
