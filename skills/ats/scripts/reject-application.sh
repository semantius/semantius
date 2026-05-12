#!/usr/bin/env bash
# reject-application.sh: Move one active job_applications row to status=rejected.
# Pairs status, rejection_reason, and rejected_at in a single PATCH so the
# platform's family of rejected_* invariants
# (rejected_status_requires_rejected_at, rejection_reason_required_when_rejected,
# rejected_at_only_when_rejected, rejection_reason_only_when_rejected,
# applied_before_rejected) accept the write. Optionally moves
# current_stage_id to the first active stage in the `rejected` category.
#
# Usage: reject-application.sh <candidate-email-or-name> <job-code> <rejection-reason>
#
# rejection-reason: one of not_qualified, withdrew, position_filled, no_show,
#   salary_mismatch, location_mismatch, culture_fit, other.
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / invalid enum / terminal-state refusal
#        2 on platform error
#
# Idempotent: re-running on an already-rejected row is a no-op (status check
# at step 3 short-circuits).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code> <rejection-reason>" >&2
  exit 1
fi

candidate_arg="$1"
job_code="$2"
reason="$3"

case "$reason" in
  not_qualified|withdrew|position_filled|no_show|salary_mismatch|location_mismatch|culture_fit|other) ;;
  *) echo "step 0: rejection-reason must be one of: not_qualified, withdrew, position_filled, no_show, salary_mismatch, location_mismatch, culture_fit, other" >&2; exit 1 ;;
esac

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

# Step 2: resolve job opening.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_code}&select=id\"}") \
  || { echo "step 2: job opening '${job_code}' not found" >&2; exit 1; }
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')

# Step 3: resolve the application (any status; surface terminal states).
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&select=id,status\"}") \
  || { echo "step 3: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
[ "$match_count" = "1" ] || { echo "step 3: expected exactly one application for candidate / job ${job_code} (${match_count} found)" >&2; exit 1; }
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
status=$(printf '%s' "$applications" | grep -oE '"status":"[^"]+"' | head -n1 | sed 's/"status":"\([^"]*\)"/\1/')

case "$status" in
  rejected) echo "reject-application: application ${application_id} is already rejected; nothing to do" >&2; exit 0 ;;
  hired) echo "step 3: application ${application_id} is already hired; rejecting a hired application is rare and almost certainly a re-key error. Withdraw or use use-semantius directly if intentional." >&2; exit 1 ;;
esac

# Step 4: optionally find the first active stage in the `rejected` category.
rejected_stages=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/application_stages?stage_category=eq.rejected&is_active=eq.true&order=stage_order.asc&limit=1&select=id\"}") \
  || { echo "step 4: rejected-stage lookup failed" >&2; exit 2; }
rejected_stage_id=$(printf '%s' "$rejected_stages" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/' || true)

# Step 5: PATCH paired fields in one call.
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ -n "$rejected_stage_id" ]; then
  body="{\"status\":\"rejected\",\"rejection_reason\":\"${reason}\",\"rejected_at\":\"${now}\",\"current_stage_id\":\"${rejected_stage_id}\"}"
else
  body="{\"status\":\"rejected\",\"rejection_reason\":\"${reason}\",\"rejected_at\":\"${now}\"}"
fi

semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":${body}}" \
  > /dev/null \
  || { echo "step 5: PATCH failed; surface platform validation_rules verbatim (rejected_status_requires_rejected_at, rejection_reason_required_when_rejected, applied_before_rejected)" >&2; exit 2; }

echo "reject-application: ok (application ${application_id} -> rejected with reason ${reason})"
