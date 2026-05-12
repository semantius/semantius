#!/usr/bin/env bash
# schedule-feature.sh: Move a feature to `planned`, optionally attaching
# it to a release and setting target dates. Refuses if the feature has
# already shipped or the release is in a terminal state.
#
# Usage: schedule-feature.sh <feature-title> [<release-name>] [<target-start-YYYY-MM-DD>] [<target-completion-YYYY-MM-DD>]
#
# Exit:  0 on success
#        1 on usage / validation failure (bad args, unresolved title or release,
#          feature already shipped, release released or cancelled,
#          target_completion before target_start)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same inputs is safe. If the feature is
# already in the requested state, the PATCH is effectively a no-op; the
# verify step still passes.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $(basename "$0") <feature-title> [<release-name>] [<target-start-YYYY-MM-DD>] [<target-completion-YYYY-MM-DD>]" >&2
  exit 1
fi

feature_title="$1"
release_name="${2:-}"
target_start="${3:-}"
target_completion="${4:-}"

# Step 1: resolve feature
feature=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${feature_title// /%20}&select=id\"}") \
  || { echo "step 1: feature '$feature_title' not found or ambiguous" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)

# Step 2: resolve release if supplied
release_id=""
if [ -n "$release_name" ]; then
  release=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/releases?release_name=eq.${release_name// /%20}&select=id,release_status\"}") \
    || { echo "step 2: release '$release_name' not found" >&2; exit 1; }
  release_id=$(printf '%s' "$release" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
  release_status=$(printf '%s' "$release" | grep -oE '"release_status":"[^"]+"' | head -n1 | cut -d'"' -f4)
  if [ "$release_status" = "released" ] || [ "$release_status" = "cancelled" ]; then
    echo "step 2: release '$release_name' is $release_status; pick a non-terminal release or omit the argument to schedule status only" >&2
    exit 1
  fi
fi

# Step 3: build PATCH body
body="{\"feature_status\":\"planned\""
if [ -n "$release_id" ]; then body="$body,\"release_id\":\"$release_id\""; fi
if [ -n "$target_start" ]; then body="$body,\"target_start_date\":\"$target_start\""; fi
if [ -n "$target_completion" ]; then body="$body,\"target_completion_date\":\"$target_completion\""; fi
body="$body}"

semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.$feature_id\",\"body\":$body}" \
  || { echo "step 3: PATCH /features failed; surface any platform code verbatim. Likely codes: feature_shipped_is_one_way (feature already shipped), target_dates_ordered (target_start after target_completion), release_only_when_committed (should not fire because we always set status=planned)" >&2; exit 2; }

# Step 4: verify
verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id,feature_status,release_id,target_start_date,target_completion_date\"}") \
  || { echo "step 4: verify read failed" >&2; exit 2; }

echo "schedule-feature: ok"
printf '%s\n' "$verify"
