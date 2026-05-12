#!/usr/bin/env bash
# transition-requisition.sh: Transition a job_openings row to a target status,
# pairing the side-effect dates the platform requires.
#
# Usage: transition-requisition.sh <job-code-or-title> <open|on_hold|filled|closed|cancelled> [yyyy-mm-dd]
#
# Mode behavior:
#   open:      sets status=open and pairs opened_at (today's date if no
#              third arg) when the row is still in draft. Required to satisfy
#              non_draft_requires_opened_at.
#   on_hold:   sets status=on_hold; pairs opened_at when transitioning out
#              of draft (rare but allowed).
#   filled:    sets status=filled and pairs filled_at (today's date if no
#              third arg). Required to satisfy filled_status_requires_filled_at.
#              The platform also enforces opened_before_filled, the script
#              surfaces the rejection verbatim if filled_at < opened_at.
#   closed:    sets status=closed; pairs opened_at when transitioning out
#              of draft.
#   cancelled: sets status=cancelled; pairs opened_at when transitioning out
#              of draft. Does NOT cascade-reject pending applications,
#              recruiters do that explicitly via reject-application.
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / invalid mode
#        2 on platform error
#
# Idempotent: re-running with the same target writes the same status/date back.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $(basename "$0") <job-code-or-title> <open|on_hold|filled|closed|cancelled> [yyyy-mm-dd]" >&2
  exit 1
fi

job_arg="$1"
target="$2"
date_arg="${3:-}"

case "$target" in open|on_hold|filled|closed|cancelled) ;; *) echo "step 0: invalid target '${target}'" >&2; exit 1 ;; esac

# Step 1: resolve job opening.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_arg}&select=id,status,opened_at,filled_at,job_title\"}" 2>/dev/null) \
  || job_opening=""
if [ -z "$job_opening" ]; then
  jobs=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).${job_arg}&select=id,status,opened_at,filled_at,job_title\"}")
  match_count=$(printf '%s' "$jobs" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: job opening not found or ambiguous (${match_count})" >&2; exit 1; }
  job_opening="$jobs"
fi
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
current_status=$(printf '%s' "$job_opening" | grep -oE '"status":"[^"]+"' | sed 's/"status":"\([^"]*\)"/\1/')
opened_at=$(printf '%s' "$job_opening" | grep -oE '"opened_at":"[^"]+"' | sed 's/"opened_at":"\([^"]*\)"/\1/' || true)

today=$(date -u +"%Y-%m-%d")
[ -z "$date_arg" ] && date_arg="$today"

# Step 2: build the PATCH body. Pair opened_at when leaving draft, pair filled_at on filled.
body="{\"status\":\"${target}\""
if [ "$current_status" = "draft" ] && [ "$target" != "draft" ]; then
  body="${body},\"opened_at\":\"${date_arg}\""
fi
if [ "$target" = "filled" ]; then
  # filled_at is the side-effect for filled status. Use date_arg if provided,
  # else today. opened_at must already be non-null (or paired in this same
  # PATCH from the draft branch above).
  body="${body},\"filled_at\":\"${date_arg}\""
  if [ "$current_status" = "draft" ] && [ -z "$opened_at" ]; then
    : # both opened_at and filled_at set above; platform will check ordering.
  fi
fi
body="${body}}"

# Step 3: PATCH.
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_openings?id=eq.${job_opening_id}\",\"body\":${body}}" \
  > /dev/null \
  || { echo "step 3: PATCH job_openings failed; if the platform code is non_draft_requires_opened_at, filled_status_requires_filled_at, opened_before_filled, or opened_before_target_start, surface verbatim and ask the user to correct the date" >&2; exit 2; }

echo "transition-requisition: job_opening ${job_opening_id} now ${target} (was ${current_status})"
