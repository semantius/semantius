#!/usr/bin/env bash
# move-application-stage.sh: Move one job_applications row to a different
# application_stages by stage_name.
#
# Usage: move-application-stage.sh <candidate-email-or-name> <job-code-or-title> <stage-name>
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / disambiguation needed
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same arguments is a no-op (the application
# is already at that stage; the PATCH writes the same value back).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code-or-title> <stage-name>" >&2
  exit 1
fi

candidate_arg="$1"
job_arg="$2"
stage_name="$3"

# Step 1: resolve candidate. Try email first; fall back to fuzzy name.
if [[ "$candidate_arg" == *@*.* ]]; then
  candidate=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.${candidate_arg}&select=id\"}") \
    || { echo "step 1: candidate '${candidate_arg}' not found by email" >&2; exit 1; }
else
  candidates=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/candidates?search_vector=wfts(simple).${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate name search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$candidates" | grep -oE '"id"' | wc -l | tr -d ' ')
  if [ "$match_count" = "0" ]; then
    echo "step 1: candidate '${candidate_arg}' not found by name; ask the user for an exact email" >&2
    exit 1
  fi
  if [ "$match_count" != "1" ]; then
    echo "step 1: candidate '${candidate_arg}' is ambiguous (${match_count} matches); ask the user to provide email_address" >&2
    exit 1
  fi
  candidate="$candidates"
fi
candidate_id=$(printf '%s' "$candidate" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 2: resolve job opening. Try job_code first; fall back to fuzzy title.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_arg}&select=id\"}" 2>/dev/null) \
  || job_opening=""
if [ -z "$job_opening" ]; then
  jobs=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).${job_arg}&select=id,job_title,job_code\"}") \
    || { echo "step 2: job opening search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$jobs" | grep -oE '"id"' | wc -l | tr -d ' ')
  if [ "$match_count" = "0" ]; then
    echo "step 2: job opening '${job_arg}' not found; ask the user for an exact job_code" >&2
    exit 1
  fi
  if [ "$match_count" != "1" ]; then
    echo "step 2: job opening '${job_arg}' is ambiguous (${match_count} matches); ask the user for an exact job_code" >&2
    exit 1
  fi
  job_opening="$jobs"
fi
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 3: resolve target stage by name (stage_name is unique).
stage=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/application_stages?stage_name=eq.${stage_name}&select=id\"}") \
  || { echo "step 3: stage '${stage_name}' not found; valid stage names are listed in application_stages" >&2; exit 1; }
stage_id=$(printf '%s' "$stage" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')

# Step 4: resolve the application by (candidate_id, job_opening_id).
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&status=eq.active&select=id,current_stage_id\"}") \
  || { echo "step 4: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$match_count" = "0" ]; then
  echo "step 4: no active application for candidate '${candidate_arg}' at job '${job_arg}'; user should run Submit-application first or unwind a terminal status via use-semantius" >&2
  exit 1
fi
if [ "$match_count" != "1" ]; then
  echo "step 4: more than one active application matched; ask the user to disambiguate" >&2
  exit 1
fi
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 5: PATCH the stage.
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":{\"current_stage_id\":\"${stage_id}\"}}" \
  > /dev/null \
  || { echo "step 5: PATCH job_applications.current_stage_id failed; if the platform code is non-trivial, surface it to the user verbatim" >&2; exit 2; }

echo "move-application-stage: application ${application_id} now at stage ${stage_name}"
