#!/usr/bin/env bash
# start-feature.sh: Move a feature from `planned` to `in_progress` and
# record `actual_start_date` in one PATCH. Refuses if the feature is
# not in `planned`.
#
# Usage: start-feature.sh <feature-title> [<actual-start-YYYY-MM-DD>]
#
# Exit:  0 on success
#        1 on usage / validation failure (bad args, unresolved title,
#          feature not in `planned`)
#        2 on platform error (semantius call failed)
#
# Idempotent: if the feature is already `in_progress` with the same
# `actual_start_date`, the recipe refuses at the status check; this is
# intentional, the operation is a state transition, not an update.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $(basename "$0") <feature-title> [<actual-start-YYYY-MM-DD>]" >&2
  exit 1
fi

feature_title="$1"
actual_start="${2:-$(date +%Y-%m-%d)}"

feature=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${feature_title// /%20}&select=id,feature_status\"}") \
  || { echo "step 1: feature '$feature_title' not found or ambiguous" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
feature_status=$(printf '%s' "$feature" | grep -oE '"feature_status":"[^"]+"' | head -n1 | cut -d'"' -f4)

if [ "$feature_status" != "planned" ]; then
  echo "step 1: feature '$feature_title' is in '$feature_status'; work can only be started from 'planned'. Run schedule-feature.sh first if needed." >&2
  exit 1
fi

semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.$feature_id\",\"body\":{\"feature_status\":\"in_progress\",\"actual_start_date\":\"$actual_start\"}}" \
  || { echo "step 2: PATCH /features failed; if the platform returned actual_start_only_when_in_progress_or_later, the status branch was bypassed; surface the platform's code verbatim" >&2; exit 2; }

verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id,feature_status,actual_start_date\"}") \
  || { echo "step 3: verify read failed" >&2; exit 2; }

echo "start-feature: ok"
printf '%s\n' "$verify"
