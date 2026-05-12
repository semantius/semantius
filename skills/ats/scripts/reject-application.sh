#!/usr/bin/env bash
# reject-application.sh: Set a job_applications row to status=rejected,
# pairing rejected_at and rejection_reason in the same PATCH (the platform
# rejects the unpaired write via rejected_status_requires_rejected_at and
# rejection_reason_only_when_rejected).
#
# Usage: reject-application.sh <candidate-email-or-name> <job-code-or-title> <rejection_reason>
#
# rejection_reason: one of not_qualified, withdrew, position_filled,
#   no_show, salary_mismatch, location_mismatch, culture_fit, other.
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / application already terminal
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same args is safe; the second run sees
# status=rejected on the active filter and exits 1 with "already rejected".
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code-or-title> <rejection_reason>" >&2
  echo "  rejection_reason: not_qualified | withdrew | position_filled | no_show | salary_mismatch | location_mismatch | culture_fit | other" >&2
  exit 1
fi

candidate_arg="$1"
job_arg="$2"
reason="$3"

case "$reason" in
  not_qualified|withdrew|position_filled|no_show|salary_mismatch|location_mismatch|culture_fit|other) ;;
  *) echo "step 0: invalid rejection_reason '${reason}'; valid: not_qualified | withdrew | position_filled | no_show | salary_mismatch | location_mismatch | culture_fit | other" >&2; exit 1 ;;
esac

# Step 1: resolve candidate.
if [[ "$candidate_arg" == *@*.* ]]; then
  candidate=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.${candidate_arg}&select=id\"}") \
    || { echo "step 1: candidate '${candidate_arg}' not found by email" >&2; exit 1; }
else
  candidates=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/candidates?search_vector=wfts(simple).${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$candidates" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: candidate '${candidate_arg}' not found or ambiguous (${match_count} matches); ask the user for email_address" >&2; exit 1; }
  candidate="$candidates"
fi
candidate_id=$(printf '%s' "$candidate" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 2: resolve job opening.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_arg}&select=id\"}" 2>/dev/null) \
  || job_opening=""
if [ -z "$job_opening" ]; then
  jobs=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).${job_arg}&select=id,job_title\"}") \
    || { echo "step 2: job opening search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$jobs" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 2: job opening '${job_arg}' not found or ambiguous (${match_count} matches); ask the user for job_code" >&2; exit 1; }
  job_opening="$jobs"
fi
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 3: resolve the active application.
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&select=id,status\"}") \
  || { echo "step 3: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$match_count" = "0" ]; then
  echo "step 3: no application for candidate '${candidate_arg}' at job '${job_arg}'" >&2
  exit 1
fi
if printf '%s' "$applications" | grep -q '"status":"rejected"\|"status":"hired"\|"status":"withdrawn"'; then
  echo "step 3: application already in a terminal status; review existing state via Read-decision-audit-trail rather than overwriting" >&2
  exit 1
fi
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 4: PATCH status, rejected_at, rejection_reason in one call.
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":{\"status\":\"rejected\",\"rejected_at\":\"${now}\",\"rejection_reason\":\"${reason}\"}}" \
  > /dev/null \
  || { echo "step 4: PATCH failed; if the platform error code is rejected_status_requires_rejected_at or rejection_reason_only_when_rejected, the live row state has drifted, surface verbatim and abort" >&2; exit 2; }

echo "reject-application: application ${application_id} rejected (${reason}) at ${now}"
