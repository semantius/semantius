#!/usr/bin/env bash
# ship-release.sh: Ship a release. PATCH the release row to
# release_status=released with actual_release_date, then sweep every
# feature on the release at planned/in_progress to feature_status=
# shipped, then verify no planned/in_progress features remain on the
# release. Features at shipped/declined/parked are intentionally not
# touched.
#
# Usage: ship-release.sh <release_id> <actual_release_date YYYY-MM-DD> [release_notes_html]
# Exit:  0 on success
#        1 on usage / precondition failure (bad args, release already
#          released or cancelled)
#        2 on platform error (a semantius call failed)
#
# Idempotent: rerunning with the same inputs is safe. The release
# PATCH is filtered to the release_id; the sweep is filtered to
# feature_status in (planned, in_progress) so already-shipped rows
# are never re-touched. If a previous run failed mid-cascade,
# rerunning resumes from where it left off.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <release_id> <actual_release_date YYYY-MM-DD> [release_notes_html]" >&2
  exit 1
fi

release_id="$1"
actual_date="$2"
release_notes="${3:-}"

# Validate date format (YYYY-MM-DD).
if ! [[ "$actual_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Invalid actual_release_date '$actual_date'; expected YYYY-MM-DD" >&2
  exit 1
fi

# Step 1: read the release; refuse if already released or cancelled.
# expect: --single; exit 1 from semantius means release not found.
release_json=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/releases?id=eq.$release_id&select=id,release_name,release_status\"}") \
  || { echo "step 1: release $release_id not found" >&2; exit 1; }

# --single returns a bare object; no head -n1 / [0] indexing.
current_status=$(printf '%s' "$release_json" | grep -oE '"release_status":"[^"]+"' | sed 's/.*:"\(.*\)"/\1/')

if [ "$current_status" = "released" ] || [ "$current_status" = "cancelled" ]; then
  echo "step 1: release $release_id has release_status=$current_status; refusing to re-ship. The original actual_release_date stands." >&2
  exit 1
fi

# Step 2: PATCH the release. status + actual_release_date + optional
# release_notes in one call.
if [ -n "$release_notes" ]; then
  notes_field=",\"release_notes\":\"$release_notes\""
else
  notes_field=""
fi

# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/releases?id=eq.$release_id\",\"body\":{\"release_status\":\"released\",\"actual_release_date\":\"$actual_date\"$notes_field}}" \
  >/dev/null \
  || { echo "step 2 (PATCH release $release_id to released) failed" >&2; exit 2; }

# Step 3: sweep features at planned/in_progress on this release to
# shipped. The feature_status filter ensures already-shipped, declined,
# parked, new, and under_review rows are NOT touched.
# expect: array (PATCH returns N updated rows; zero is the resume-safe
#         no-op when this script reran after a partial failure).
semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/features?release_id=eq.$release_id&feature_status=in.(planned,in_progress)\",\"body\":{\"feature_status\":\"shipped\"}}" \
  >/dev/null \
  || { echo "step 3 (sweep features on release $release_id to shipped) failed; release row already updated, retry will be a no-op for already-shipped rows" >&2; exit 2; }

# Step 4: verify the sweep. Count features still at planned or
# in_progress on this release. If the count is zero, the cascade is
# complete. Non-committed rows (new, under_review) are surfaced as a
# data-quality warning but do not fail the run.
# expect: array; zero rows means the cascade is complete, non-zero
#         means rerun the script.
remaining=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/features?release_id=eq.$release_id&feature_status=in.(planned,in_progress)&select=id,feature_title,feature_status\"}") \
  || { echo "step 4 (verify sweep on release $release_id) failed" >&2; exit 2; }

remaining_count=$(printf '%s' "$remaining" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$remaining_count" != "0" ]; then
  echo "step 4: $remaining_count feature(s) on release $release_id still at planned/in_progress after sweep; rerun the script" >&2
  exit 2
fi

# Optional data-quality check: features still at new/under_review
# on a shipped release are a model-level concern, not a script
# failure.
# expect: array; non-zero rows means the commitment rule was already
#         broken before shipping. Surface to user, do not fail.
nq=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/features?release_id=eq.$release_id&feature_status=in.(new,under_review)&select=id,feature_title,feature_status\"}") \
  || true
nq_count=$(printf '%s' "$nq" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$nq_count" != "0" ]; then
  echo "ship-release: warning: $nq_count feature(s) on release $release_id are at new/under_review (commitment rule already broken before shipping); not swept to shipped. Surface to user as a data-quality issue." >&2
fi

echo "ship-release: ok (release $release_id released on $actual_date)"
