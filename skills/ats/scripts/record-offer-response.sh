#!/usr/bin/env bash
# record-offer-response.sh: Record a candidate's response to an offer and
# cascade the application terminal status when the response is `accepted`.
#
# Cascade flow on `accepted`:
#   1) PATCH offers: candidate_response, responded_at, status (accepted).
#   2) PATCH job_applications: status=hired, hired_at.
#   3) PATCH candidates: candidate_status=hired.
#
# On `declined`: PATCH offers only (candidate_response, responded_at,
# status=declined). The application stays active; recruiter typically
# rejects with reason=salary_mismatch / location_mismatch via reject-application.
#
# On `no_response`: PATCH offers (candidate_response, responded_at,
# status=expired). Application stays active.
#
# This script does NOT auto-fill the requisition. Decreasing headcount or
# flipping job_openings.status=filled is a separate JTBD; the script reports
# how many hires the opening still needs after the cascade.
#
# Usage: record-offer-response.sh <candidate-email-or-name> <job-code-or-title> <accepted|declined|no_response>
#
# Exit:  0 on success
#        1 on usage / unresolved lookup
#        2 on platform error
#
# Idempotent: filters select active offers (status in draft/pending_approval/
# approved/sent); a re-run after acceptance finds zero such offers and exits 1
# with "no active offer".
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code-or-title> <accepted|declined|no_response>" >&2
  exit 1
fi

candidate_arg="$1"
job_arg="$2"
response="$3"

case "$response" in accepted|declined|no_response) ;; *) echo "step 0: response must be accepted, declined, or no_response" >&2; exit 1 ;; esac

# Step 1: resolve candidate + job opening (parallel-fetch by id when possible).
if [[ "$candidate_arg" == *@*.* ]]; then
  candidate=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.${candidate_arg}&select=id\"}") \
    || { echo "step 1: candidate '${candidate_arg}' not found" >&2; exit 1; }
else
  candidates=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/candidates?search_vector=wfts(simple).${candidate_arg}&select=id\"}")
  match_count=$(printf '%s' "$candidates" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: candidate not found or ambiguous (${match_count})" >&2; exit 1; }
  candidate="$candidates"
fi
candidate_id=$(printf '%s' "$candidate" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_arg}&select=id,job_title,headcount\"}" 2>/dev/null) \
  || job_opening=""
if [ -z "$job_opening" ]; then
  jobs=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).${job_arg}&select=id,job_title,headcount\"}")
  match_count=$(printf '%s' "$jobs" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: job opening not found or ambiguous (${match_count})" >&2; exit 1; }
  job_opening="$jobs"
fi
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
headcount=$(printf '%s' "$job_opening" | grep -oE '"headcount":[0-9]+' | head -n1 | sed 's/"headcount"://')

# Step 2: resolve application (single active row expected).
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&status=eq.active&select=id\"}") \
  || { echo "step 2: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
[ "$match_count" = "1" ] || { echo "step 2: active application not found or ambiguous (${match_count})" >&2; exit 1; }
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 3: resolve the active offer.
offers=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/offers?application_id=eq.${application_id}&status=in.(draft,pending_approval,approved,sent)&select=id,status\"}") \
  || { echo "step 3: offer lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$offers" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$match_count" = "0" ]; then
  echo "step 3: no active offer (draft/pending_approval/approved/sent) on application ${application_id}; check existing offer status before retrying" >&2
  exit 1
fi
if [ "$match_count" != "1" ]; then
  echo "step 3: more than one active offer on application ${application_id}; ask the user to rescind the parallel offer first" >&2
  exit 1
fi
offer_id=$(printf '%s' "$offers" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Step 4: PATCH the offer.
case "$response" in
  accepted) offer_status="accepted" ;;
  declined) offer_status="declined" ;;
  no_response) offer_status="expired" ;;
esac
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/offers?id=eq.${offer_id}\",\"body\":{\"candidate_response\":\"${response}\",\"responded_at\":\"${now}\",\"status\":\"${offer_status}\"}}" \
  > /dev/null \
  || { echo "step 4: PATCH offers failed; if the platform code is responded_at_required_when_responded or extended_before_responded, surface it verbatim and abort" >&2; exit 2; }

# Step 5: cascade only on accepted.
if [ "$response" = "accepted" ]; then
  semantius call crud postgrestRequest --single \
    "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":{\"status\":\"hired\",\"hired_at\":\"${now}\"}}" \
    > /dev/null \
    || { echo "step 5a: PATCH job_applications.status=hired failed; offer is already accepted, retry will be a no-op for the offer step" >&2; exit 2; }
  semantius call crud postgrestRequest --single \
    "{\"method\":\"PATCH\",\"path\":\"/candidates?id=eq.${candidate_id}\",\"body\":{\"candidate_status\":\"hired\"}}" \
    > /dev/null \
    || { echo "step 5b: PATCH candidates.candidate_status=hired failed; application is already hired, retry will be a no-op for steps 4-5a" >&2; exit 2; }

  # Step 6: report remaining headcount.
  hired_count=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_applications?job_opening_id=eq.${job_opening_id}&status=eq.hired&select=id\"}" \
    | grep -oE '"id"' | wc -l | tr -d ' ')
  remaining=$((headcount - hired_count))
  echo "record-offer-response: candidate ${candidate_id} accepted; application ${application_id} hired; opening still needs ${remaining} more hire(s) of ${headcount}"
else
  echo "record-offer-response: offer ${offer_id} marked ${offer_status} (response=${response}); application ${application_id} stays active"
fi
