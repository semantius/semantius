#!/usr/bin/env bash
# schedule-feature.sh: Attach or detach a committed feature against a release.
# PATCH features.release_id while feature_status is planned or in_progress.
#
# Usage: schedule-feature.sh <feature-title> <release-name|--detach>
#
# Attach: schedule-feature.sh "Dark mode" "Release 3.4"
# Detach: schedule-feature.sh "Dark mode" --detach
#
# Exit:  0 on success
#        1 on usage/validation failure (bad args, lookup failed, wrong
#          source status, target release not transitionable)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running an attach to the same release on the same feature
# is a deterministic no-op; re-running a detach on a feature with no release
# is a no-op.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <feature-title> <release-name|--detach>" >&2
  exit 1
fi

feature_title="$1"
target="$2"

enc_title=$(printf '%s' "$feature_title" | jq -sRr @uri)

# Step 1: resolve the feature
feature=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${enc_title}&select=id,feature_title,feature_status,release_id\"}") \
  || { echo "step 1: feature '$feature_title' not found or ambiguous; try the exact title" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | jq -r '.id')
current_status=$(printf '%s' "$feature" | jq -r '.feature_status')
current_release=$(printf '%s' "$feature" | jq -r '.release_id // empty')

# Step 2: refuse if the feature is not in a status that accepts release
# changes
case "$current_status" in
  planned|in_progress)
    ;;
  shipped)
    echo "step 2: feature '$feature_title' is shipped; features_locked_when_release_is_released blocks any release change. Create a new feature record if the work needs re-scheduling." >&2
    exit 1
    ;;
  new|under_review|declined|parked)
    echo "step 2: feature '$feature_title' is '$current_status'; release_only_when_committed requires planned, in_progress, or shipped. Triage the feature to 'planned' first." >&2
    exit 1
    ;;
esac

# Step 3: branch on attach vs detach
if [ "$target" = "--detach" ]; then
  # Detach: clear release_id
  if [ -z "$current_release" ]; then
    echo "schedule-feature: '$feature_title' has no release attached (no-op)"
    exit 0
  fi
  body='{"release_id": null}'
  action="detached"
else
  # Attach: resolve the target release and refuse if cancelled (no
  # platform rule prevents attaching to a cancelled release, so this is
  # a workflow gate). The released case and the prior-release-was-released
  # case are left to the platform: features_locked_when_release_is_released
  # rejects both with a clear message; surface verbatim.
  enc_release=$(printf '%s' "$target" | jq -sRr @uri)
  release=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/releases?release_name=eq.${enc_release}&select=id,release_name,release_status\"}") \
    || { echo "step 3: release '$target' not found" >&2; exit 1; }

  release_id=$(printf '%s' "$release" | jq -r '.id')
  release_status=$(printf '%s' "$release" | jq -r '.release_status')

  if [ "$release_status" = "cancelled" ]; then
    echo "step 3: release '$target' is cancelled; scheduling into a cancelled release has no domain meaning." >&2
    exit 1
  fi

  if [ "$current_release" = "$release_id" ]; then
    echo "schedule-feature: '$feature_title' is already attached to '$target' (no-op)"
    exit 0
  fi

  body=$(jq -nc --arg r "$release_id" '{release_id: $r}')
  action="attached to '$target'"
fi

# Step 4: PATCH
semantius call crud postgrestRequest \
  "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.${feature_id}\",\"body\":${body}}" >/dev/null \
  || { echo "step 4 (schedule) failed; surface any platform validation_rules code/message verbatim. Likely codes: features_locked_when_release_is_released (the target release is released, or the feature was previously attached to a released release)." >&2; exit 2; }

echo "schedule-feature: '$feature_title' $action"
