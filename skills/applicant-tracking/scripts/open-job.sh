#!/usr/bin/env bash
# open-job.sh: PATCH a draft job_openings row to status=open and stamp
# opened_at. Refuses if the job is not draft, not found, or ambiguous.
#
# Usage: open-job.sh <job_id_or_code>
#   <job_id_or_code> may be a UUID, a job_code (e.g. ENG-2026-014),
#   or a fuzzy term that resolves to exactly one job_opening.
#
# Exit:  0 on success
#        1 on usage / validation failure (not draft, not found, ambiguous)
#        2 on platform error (semantius call failed)
#
# Idempotent: a re-run on an already-open row exits 1 with a clear
# message rather than re-stamping opened_at.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $(basename "$0") <job_id_or_code>" >&2
  exit 1
fi
arg="$1"

uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Step 1: resolve the job opening to a single row.
# id and job_code are both unique → --single (zero or many is an error).
# Fuzzy search → array (zero/one/many is the answer).
if [[ "$arg" =~ $uuid_re ]]; then
  row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/job_openings?id=eq.$arg&select=id,job_title,status\"}") \
    || { echo "step 1: no job_opening with id '$arg'" >&2; exit 1; }
else
  # Try job_code first; --single fails fast if zero or >1 rows match.
  if row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.$arg&select=id,job_title,status\"}" 2>/dev/null); then
    :
  else
    # Fall back to fuzzy search; here zero/many is a normal branch
    # (the user passed a free-form term), so use array mode.
    rows=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).$arg&select=id,job_title,status\"}") \
      || { echo "step 1 (fuzzy read job_openings) failed" >&2; exit 2; }
    count=$(printf '%s' "$rows" | grep -o '"id"' | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
      echo "step 1: no job_opening matched '$arg'; ask the user for a different term" >&2
      exit 1
    fi
    if [ "$count" -gt 1 ]; then
      echo "step 1: '$arg' matched $count job_openings; ask the user to disambiguate" >&2
      printf '%s\n' "$rows" >&2
      exit 1
    fi
    # Exactly one match: collapse to bare-object shape for downstream parsing.
    row=$(printf '%s' "$rows" | sed -E 's/^\[(.*)\]$/\1/')
  fi
fi

# row is a bare object: {"id":"...","job_title":"...","status":"..."}
job_id=$(printf '%s' "$row" | grep -oE '"id":"[^"]+"' | sed -E 's/.*"id":"([^"]+)".*/\1/')
current_status=$(printf '%s' "$row" | grep -oE '"status":"[^"]+"' | sed -E 's/.*"status":"([^"]+)".*/\1/')

# Step 2: validate current status.
if [ "$current_status" != "draft" ]; then
  echo "step 2: job_opening $job_id is in status '$current_status'; only draft can be opened" >&2
  exit 1
fi

# Step 3: PATCH to status=open with today's date.
today=$(date -u +"%Y-%m-%d")

semantius call crud postgrestRequest --single "{\"method\":\"PATCH\",\"path\":\"/job_openings?id=eq.$job_id\",\"body\":{\"status\":\"open\",\"opened_at\":\"$today\"}}" \
  >/dev/null \
  || { echo "step 3 (PATCH job_openings) failed" >&2; exit 2; }

# Step 4: verify the post-condition (the row must exist; we just wrote it).
verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/job_openings?id=eq.$job_id&select=status,opened_at\"}") \
  || { echo "step 4 (verify) failed" >&2; exit 2; }

if ! printf '%s' "$verify" | grep -q '"status":"open"'; then
  echo "step 4: PATCH applied but verify shows status not 'open'; investigate manually" >&2
  exit 2
fi

echo "open-job: ok ($job_id, opened_at=$today)"
