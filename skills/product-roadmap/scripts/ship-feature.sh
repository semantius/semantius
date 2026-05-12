#!/usr/bin/env bash
# ship-feature.sh: Move a feature from `in_progress` to `shipped`,
# attaching the release if not already set, and record
# `actual_completion_date`. Refuses if the feature is not in
# `in_progress` or completion precedes start.
#
# Usage: ship-feature.sh <feature-title> [<release-name>] [<actual-completion-YYYY-MM-DD>]
#
# Exit:  0 on success
#        1 on usage / validation failure (bad args, unresolved title or release,
#          feature not in `in_progress`, no release available,
#          completion before start, release in terminal state)
#        2 on platform error (semantius call failed)
#
# Idempotent: if the feature is already `shipped`, the platform rejects
# any further write via feature_shipped_is_one_way; the recipe surfaces
# that and exits non-zero. The operation is a one-way transition.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <feature-title> [<release-name>] [<actual-completion-YYYY-MM-DD>]" >&2
  exit 1
fi

feature_title="$1"
release_name="${2:-}"
actual_completion="${3:-$(date +%Y-%m-%d)}"

feature=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${feature_title// /%20}&select=id,feature_status,release_id\"}") \
  || { echo "step 1: feature '$feature_title' not found or ambiguous" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
feature_status=$(printf '%s' "$feature" | grep -oE '"feature_status":"[^"]+"' | head -n1 | cut -d'"' -f4)
existing_release_id=$(printf '%s' "$feature" | grep -oE '"release_id":"[^"]+"' | head -n1 | cut -d'"' -f4 || true)

if [ "$feature_status" != "in_progress" ]; then
  echo "step 1: feature '$feature_title' is in '$feature_status'; can only ship from 'in_progress'. Run start-feature.sh first if needed." >&2
  exit 1
fi

# Step 2: resolve release if supplied
release_id="$existing_release_id"
if [ -n "$release_name" ]; then
  release=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/releases?release_name=eq.${release_name// /%20}&select=id\"}") \
    || { echo "step 2: release '$release_name' not found" >&2; exit 1; }
  release_id=$(printf '%s' "$release" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
fi

# Step 3: ship in one PATCH (status + release_id + actual_completion_date).
# release_id may be null; the platform's release_required_when_shipped will
# reject in that case and we surface the code to the user.
body="{\"feature_status\":\"shipped\",\"actual_completion_date\":\"$actual_completion\""
if [ -n "$release_id" ]; then body="$body,\"release_id\":\"$release_id\""; fi
body="$body}"

semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.$feature_id\",\"body\":$body}" \
  || { echo "step 3: PATCH /features failed; surface any platform code verbatim. Likely codes: release_required_when_shipped (no release on feature, supply <release-name>), actual_dates_ordered (completion before start), feature_shipped_is_one_way (already shipped)" >&2; exit 2; }

verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id,feature_status,release_id,actual_completion_date\"}") \
  || { echo "step 4: verify read failed" >&2; exit 2; }

echo "ship-feature: ok"
printf '%s\n' "$verify"
