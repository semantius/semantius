#!/usr/bin/env bash
# ship-feature.sh: Ship a feature into a release. PATCH status=shipped,
# release_id, actual_start_date, actual_completion_date in one call.
#
# Usage: ship-feature.sh <feature-title> <release-name> [actual-completion-date YYYY-MM-DD]
#
# Exit:  0 on success
#        1 on usage/validation failure (bad args, lookup failed,
#          release not transitionable, feature already shipped)
#        2 on platform error (semantius call failed)
#
# Idempotent: a re-run on a feature already shipped into the same release
# with the same actual dates exits 0 with a no-op message; a re-run that
# would change anything on a shipped feature exits 1 (one-way terminal).
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <feature-title> <release-name> [actual-completion-date YYYY-MM-DD]" >&2
  exit 1
fi

feature_title="$1"
release_name="$2"
completion_date="${3:-$(date -u +%Y-%m-%d)}"

enc_title=$(printf '%s' "$feature_title" | jq -sRr @uri)
enc_release=$(printf '%s' "$release_name" | jq -sRr @uri)

# Step 1: parallel-fetch (no dependency between these reads)
# 1a: resolve the feature by title
feature=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${enc_title}&select=id,feature_title,feature_status,release_id,actual_start_date,actual_completion_date\"}") \
  || { echo "step 1a: feature '$feature_title' not found or ambiguous; try the exact title" >&2; exit 1; }

# 1b: resolve the release by name
release=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/releases?release_name=eq.${enc_release}&select=id,release_name,release_status\"}") \
  || { echo "step 1b: release '$release_name' not found" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | jq -r '.id')
current_status=$(printf '%s' "$feature" | jq -r '.feature_status')
current_release=$(printf '%s' "$feature" | jq -r '.release_id // empty')
existing_start=$(printf '%s' "$feature" | jq -r '.actual_start_date // empty')
existing_completion=$(printf '%s' "$feature" | jq -r '.actual_completion_date // empty')

release_id=$(printf '%s' "$release" | jq -r '.id')
release_status=$(printf '%s' "$release" | jq -r '.release_status')

# Step 2: refuse if the feature is already shipped (one-way terminal)
if [ "$current_status" = "shipped" ]; then
  if [ "$current_release" = "$release_id" ] \
     && [ "$existing_completion" = "$completion_date" ]; then
    echo "ship-feature: '$feature_title' is already shipped in '$release_name' on $completion_date (no-op)"
    exit 0
  fi
  echo "step 2: feature '$feature_title' is already shipped; feature_shipped_is_one_way blocks any further changes. To re-ship under a different release/date, create a new feature record." >&2
  exit 1
fi

# Step 3: refuse if the target release is cancelled (no platform rule
# blocks shipping into a cancelled release, so this is a workflow gate).
# The released case is left to the platform: features_locked_when_release_is_released
# rejects the attach with a clear message; surface verbatim.
if [ "$release_status" = "cancelled" ]; then
  echo "step 3: release '$release_name' is cancelled; shipping into a cancelled release has no domain meaning. Pick a different release." >&2
  exit 1
fi

# Step 4: compose actual_start_date. Prefer any existing value (set when
# the feature was started), fall back to the completion date so the
# actual_dates_ordered rule passes when shipping without a prior start.
start_date="${existing_start:-$completion_date}"

# Step 5: PATCH status + release + both actual dates in one call.
# rice_score is in computed_fields (platform-derived); never include it.
body=$(jq -nc \
  --arg s "shipped" \
  --arg r "$release_id" \
  --arg sd "$start_date" \
  --arg cd "$completion_date" \
  '{feature_status: $s, release_id: $r, actual_start_date: $sd, actual_completion_date: $cd}')

semantius call crud postgrestRequest \
  "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.${feature_id}\",\"body\":${body}}" >/dev/null \
  || { echo "step 5 (ship) failed; surface any platform validation_rules code/message verbatim. Likely codes: features_locked_when_release_is_released (target release is already released, or the feature was previously attached to a released release), actual_dates_ordered (start > completion)." >&2; exit 2; }

echo "ship-feature: '$feature_title' shipped in '$release_name' (start=$start_date, completion=$completion_date)"
