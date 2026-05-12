#!/usr/bin/env bash
# record-offer-response.sh: Record the candidate's response to a sent offer.
# Cascades on `accepted` through three writes:
#   1. offers.status=accepted, candidate_response=accepted, responded_at=<now>
#   2. job_applications.status=hired, hired_at=<now>, current_stage_id=<first
#      active hired-category stage when one exists>
#   3. candidates.candidate_status=hired
# On `declined` or `no_response`, writes only the offer row; the application
# stays at its current stage so the recruiter can reject explicitly or
# re-engage. The platform pairs responded_at with candidate_response via
# responded_at_required_when_responded / responded_at_only_when_responded;
# the script pairs them in one PATCH.
#
# Usage: record-offer-response.sh <candidate-email-or-name> <job-code> <accepted|declined|no_response>
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / not-sent-yet / multi-active-offer
#        2 on platform error
#
# Idempotent: re-running on a row already at the target response is a no-op
# (the candidate_response check at step 4 short-circuits).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <job-code> <accepted|declined|no_response>" >&2
  exit 1
fi

candidate_arg="$1"
job_code="$2"
response="$3"

case "$response" in accepted|declined|no_response) ;; *) echo "step 0: response must be accepted, declined, or no_response" >&2; exit 1 ;; esac

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

# Step 3: resolve application.
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&job_opening_id=eq.${job_opening_id}&select=id,status\"}") \
  || { echo "step 3: application lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$applications" | grep -oE '"id"' | wc -l | tr -d ' ')
[ "$match_count" = "1" ] || { echo "step 3: expected exactly one application for candidate / job ${job_code} (${match_count} found)" >&2; exit 1; }
application_id=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 4: resolve the active offer. Must exist, must be in `sent`, and there must be exactly one.
offers=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/offers?application_id=eq.${application_id}&status=in.(sent,approved,pending_approval,draft)&select=id,status,candidate_response\"}") \
  || { echo "step 4a: offer lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$offers" | grep -oE '"id"' | wc -l | tr -d ' ')
[ "$match_count" != "0" ] || { echo "step 4a: no active offer found on application ${application_id}; nothing to record a response against" >&2; exit 1; }
[ "$match_count" = "1" ] || { echo "step 4a: more than one active offer (${match_count}) on application ${application_id}; rescind the duplicates via use-semantius first" >&2; exit 1; }
offer_id=$(printf '%s' "$offers" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
offer_status=$(printf '%s' "$offers" | grep -oE '"status":"[^"]+"' | head -n1 | sed 's/"status":"\([^"]*\)"/\1/')
existing_response=$(printf '%s' "$offers" | grep -oE '"candidate_response":"[^"]+"' | head -n1 | sed 's/"candidate_response":"\([^"]*\)"/\1/')

[ "$offer_status" = "sent" ] || { echo "step 4b: offer ${offer_id} is at status=${offer_status}; it must be sent before a response can be recorded. Use extend-offer to send first." >&2; exit 1; }

if [ "$existing_response" = "$response" ]; then
  echo "record-offer-response: offer ${offer_id} already at candidate_response=${response}; nothing to do" >&2
  exit 0
fi

now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
today=$(date -u +"%Y-%m-%d")

# Step 5: write offer row. On accepted, pair status -> accepted; on declined / no_response, pair status accordingly.
case "$response" in
  accepted) offer_target_status="accepted" ;;
  declined) offer_target_status="declined" ;;
  no_response) offer_target_status="expired" ;;
esac
offer_body="{\"status\":\"${offer_target_status}\",\"candidate_response\":\"${response}\",\"responded_at\":\"${now}\"}"
semantius call crud postgrestRequest --single \
  "{\"method\":\"PATCH\",\"path\":\"/offers?id=eq.${offer_id}\",\"body\":${offer_body}}" \
  > /dev/null \
  || { echo "step 5: PATCH offers failed; surface platform code verbatim (responded_at_required_when_responded, extended_before_responded)" >&2; exit 2; }

# Step 6: cascade on accepted only.
if [ "$response" = "accepted" ]; then
  hired_stages=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/application_stages?stage_category=eq.hired&is_active=eq.true&order=stage_order.asc&limit=1&select=id\"}") \
    || { echo "step 6a: hired-stage lookup failed" >&2; exit 2; }
  hired_stage_id=$(printf '%s' "$hired_stages" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/' || true)

  if [ -n "$hired_stage_id" ]; then
    app_body="{\"status\":\"hired\",\"hired_at\":\"${now}\",\"current_stage_id\":\"${hired_stage_id}\"}"
  else
    app_body="{\"status\":\"hired\",\"hired_at\":\"${now}\"}"
  fi
  semantius call crud postgrestRequest --single \
    "{\"method\":\"PATCH\",\"path\":\"/job_applications?id=eq.${application_id}\",\"body\":${app_body}}" \
    > /dev/null \
    || { echo "step 6b: PATCH job_applications failed; surface platform code verbatim (hired_status_requires_hired_at, applied_before_hired). The offer row already updated; rerun this script to retry idempotently." >&2; exit 2; }

  semantius call crud postgrestRequest --single \
    "{\"method\":\"PATCH\",\"path\":\"/candidates?id=eq.${candidate_id}\",\"body\":{\"candidate_status\":\"hired\"}}" \
    > /dev/null \
    || { echo "step 6c: PATCH candidates failed; the offer and application rows already updated; rerun this script to retry idempotently." >&2; exit 2; }
fi

echo "record-offer-response: ok (offer ${offer_id} -> ${offer_target_status}, candidate_response=${response})"
