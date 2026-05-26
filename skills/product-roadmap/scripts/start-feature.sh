#!/usr/bin/env bash
# start-feature.sh: Move a feature to in_progress with paired actual_start_date.
#
# Usage: start-feature.sh <feature-title> [actual-start-date YYYY-MM-DD]
#
# Exit:  0 on success (transition applied or already in_progress)
#        1 on usage/validation failure (bad args, feature not found,
#          ambiguous title, wrong source status)
#        2 on platform error (semantius call failed)
#
# Idempotent: a re-run on a feature already in in_progress with the same
# actual_start_date is a deterministic no-op.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $(basename "$0") <feature-title> [actual-start-date YYYY-MM-DD]" >&2
  exit 1
fi

feature_title="$1"
start_date="${2:-$(date -u +%Y-%m-%d)}"

enc_title=$(printf '%s' "$feature_title" | jq -sRr @uri)

# Step 1: resolve the feature by title (titles are non-unique, --single
# refuses ambiguous matches)
feature=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${enc_title}&select=id,feature_title,feature_status,actual_start_date\"}") \
  || { echo "step 1: feature '$feature_title' not found or ambiguous; try the exact title" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | jq -r '.id')
current_status=$(printf '%s' "$feature" | jq -r '.feature_status')
existing_start=$(printf '%s' "$feature" | jq -r '.actual_start_date // empty')

# Step 2: refuse if the feature is not in a transitionable status
case "$current_status" in
  planned)
    ;;
  in_progress)
    if [ -n "$existing_start" ] && [ "$existing_start" = "$start_date" ]; then
      echo "start-feature: '$feature_title' is already in_progress with actual_start_date=$start_date (no-op)"
      exit 0
    fi
    ;;
  *)
    echo "step 2: feature '$feature_title' is in '$current_status'; start requires 'planned' or 'in_progress'. Triage to 'planned' first." >&2
    exit 1
    ;;
esac

# Step 3: PATCH status + actual_start_date in one call
body=$(jq -nc \
  --arg s "in_progress" \
  --arg d "$start_date" \
  '{feature_status: $s, actual_start_date: $d}')

semantius call crud postgrestRequest \
  "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.${feature_id}\",\"body\":${body}}" >/dev/null \
  || { echo "step 3 (start) failed; surface any platform validation_rules code/message verbatim (e.g. actual_dates_ordered if actual_completion_date is set in the past)" >&2; exit 2; }

echo "start-feature: '$feature_title' moved to in_progress with actual_start_date=$start_date"
