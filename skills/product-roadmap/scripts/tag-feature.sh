#!/usr/bin/env bash
# tag-feature.sh: Link a feature to an existing tag via the feature_tags
# junction. The (feature_id, tag_id) junction has no DB-level uniqueness,
# so the script reads first and no-ops if the link already exists.
# feature_tag_label is in computed_fields (platform-derived); never
# include it in the body.
#
# Usage: tag-feature.sh <feature-title> <tag-name>
#
# Exit:  0 on success (insert or no-op)
#        1 on usage/validation failure (bad args, feature not found
#          or ambiguous, tag not found)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running on an already-tagged feature is a no-op.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <feature-title> <tag-name>" >&2
  exit 1
fi

feature_title="$1"
tag_name="$2"

enc_title=$(printf '%s' "$feature_title" | jq -sRr @uri)
enc_tag=$(printf '%s' "$tag_name" | jq -sRr @uri)

# Step 1: parallel-fetch (no dependency between these reads)
# 1a: resolve the feature by title
feature=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${enc_title}&select=id,feature_title\"}") \
  || { echo "step 1a: feature '$feature_title' not found or ambiguous; try the exact title" >&2; exit 1; }

# 1b: resolve the tag by name (tag_name is unique)
tag=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/tags?tag_name=eq.${enc_tag}&select=id,tag_name\"}") \
  || { echo "step 1b: tag '$tag_name' not found; new tags require product_roadmap:admin and are not part of this recipe. Ask an administrator to add it first." >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | jq -r '.id')
tag_id=$(printf '%s' "$tag" | jq -r '.id')

# Step 2: dedupe (junction has no DB-level uniqueness)
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/feature_tags?feature_id=eq.${feature_id}&tag_id=eq.${tag_id}&select=id\"}") \
  || { echo "step 2 (dedupe read) failed" >&2; exit 2; }

if printf '%s' "$existing" | jq -e 'length > 0' >/dev/null; then
  echo "tag-feature: '$feature_title' is already tagged '$tag_name' (no-op)"
  exit 0
fi

# Step 3: POST the junction row. feature_tag_label is platform-computed
# and must not appear in the body.
body=$(jq -nc \
  --arg f "$feature_id" \
  --arg t "$tag_id" \
  '{feature_id: $f, tag_id: $t}')

semantius call crud postgrestRequest \
  "{\"method\":\"POST\",\"path\":\"/feature_tags\",\"body\":${body}}" >/dev/null \
  || { echo "step 3 (insert feature_tag) failed; surface any platform code/message verbatim" >&2; exit 2; }

echo "tag-feature: '$feature_title' tagged '$tag_name'"
