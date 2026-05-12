#!/usr/bin/env bash
# move-application-stage.sh: Advance one active job_applications row to a
# target application_stages row. Resolves the application from
# (candidate, job_code), confirms the target stage exists and is active,
# refuses moves into the `rejected` or `hired` categories (route to the
# dedicated reject / hire JTBDs), then PATCHes current_stage_id.
#
# Usage: move-application-stage.sh <candidate-email-or-name> <job-code> <target-stage-name-or-order>
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / category-refused move
#        2 on platform error
#
# Idempotent: re-running with the same target stage is a no-op (the PATCH
# writes the same stage id; the platform accepts the redundant write).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code> <target-stage-name-or-order>" >&2
  exit 1
fi

candidate_arg="$1"
job_code="$2"
target_stage_arg="$3"

# Step 1: resolve candidate.
if [[ "$candidate_arg" == *@*.* ]]; then
  candidate=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate '${candidate_arg}' not found by email" >&2; exit 1; }
else
  candidates=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/candidates?search_vector=wfts(simple).${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$candidates" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: candidate '${candidate_arg}' ambiguous or missing (${match_count} matches)" >&2; exit 1; }
  candidate="$candidates"
fi
candidate_id=$(printf '%s' "$candidate" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 2: resolve job opening by job_code (unique).
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_code}&select=id,job_title\"}") \
  || { echo "step 2: job opening '${job_code}' not found" >&2; exit 1; }
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')

# Step 3: resolve the active application for (candidate, opening).
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&status=eq.active&select=id,current_stage_id\"}") \
  || { echo "step 3: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
[ "$match_count" = "1" ] || { echo "step 3: expected exactly one active application for candidate / job ${job_code} (${match_count} found)" >&2; exit 1; }
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 4: resolve target stage. Accept either stage_name (unique) or stage_order (unique integer).
if [[ "$target_stage_arg" =~ ^[0-9]+$ ]]; then
  stage_filter="stage_order=eq.${target_stage_arg}"
else
  stage_filter="stage_name=eq.${target_stage_arg}"
fi
stage=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/application_stages?${stage_filter}&is_active=eq.true&select=id,stage_name,stage_category\"}") \
  || { echo "step 4: target stage '${target_stage_arg}' not found or inactive" >&2; exit 1; }
stage_id=$(printf '%s' "$stage" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
stage_category=$(printf '%s' "$stage" | grep -oE '"stage_category":"[^"]+"' | sed 's/"stage_category":"\([^"]*\)"/\1/')

# Step 5: refuse moves into terminal-category stages; route to dedicated JTBDs.
case "$stage_category" in
  rejected) echo "step 5: target stage is in the 'rejected' category; use reject-application.sh instead (it pairs status, rejection_reason, and rejected_at)" >&2; exit 1 ;;
  hired) echo "step 5: target stage is in the 'hired' category; use record-offer-response.sh instead (it cascades through offer acceptance and pairs hired_at)" >&2; exit 1 ;;
esac

# Step 6: PATCH current_stage_id.
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":{\"current_stage_id\":\"${stage_id}\"}}" \
  > /dev/null \
  || { echo "step 6: PATCH job_applications failed; surface platform errors verbatim" >&2; exit 2; }

echo "move-application-stage: ok (application ${application_id} moved to stage ${stage_id})"
