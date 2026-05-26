#!/usr/bin/env bash
# cast-vote.sh: Cast or update a user's vote on a feature. The
# (feature_id, user_id) junction has no DB-level uniqueness, so the
# script reads first and either inserts a new vote or PATCHes the
# existing row's vote_weight and voted_at. feature_vote_label is in
# computed_fields (platform-derived); never include it in the body.
#
# Usage: cast-vote.sh <user-email> <feature-title> [vote-weight, default 1]
#
# Exit:  0 on success (insert or update)
#        1 on usage/validation failure (bad args, user not found,
#          feature not found or ambiguous)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same weight is a deterministic no-op
# at the data level (PATCH writes the same weight and a new voted_at).
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <user-email> <feature-title> [vote-weight, default 1]" >&2
  exit 1
fi

user_email="$1"
feature_title="$2"
vote_weight="${3:-1}"
voted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Reject only non-integer weights here (the platform's argument parser
# would surface a generic JSON-type error rather than the domain
# message). vote_weight_positive on the server enforces >= 1; do not
# duplicate that here.
case "$vote_weight" in
  ''|*[!0-9]*)
    echo "step 0: vote-weight '$vote_weight' is not an integer" >&2
    exit 1
    ;;
esac

enc_email=$(printf '%s' "$user_email" | jq -sRr @uri)
enc_title=$(printf '%s' "$feature_title" | jq -sRr @uri)

# Step 1: parallel-fetch (no dependency between these reads)
# 1a: resolve the user by email (email is unique)
user=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email=eq.${enc_email}&select=id,display_name\"}") \
  || { echo "step 1a: user '$user_email' not found" >&2; exit 1; }

# 1b: resolve the feature by title (titles are non-unique, --single
# refuses ambiguous matches)
feature=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${enc_title}&select=id,feature_title,feature_status\"}") \
  || { echo "step 1b: feature '$feature_title' not found or ambiguous; try the exact title" >&2; exit 1; }

user_id=$(printf '%s' "$user" | jq -r '.id')
feature_id=$(printf '%s' "$feature" | jq -r '.id')

# Step 2: dedupe (junction has no DB-level uniqueness)
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/feature_votes?feature_id=eq.${feature_id}&user_id=eq.${user_id}&select=id\"}") \
  || { echo "step 2 (dedupe read) failed" >&2; exit 2; }

# Step 3: PATCH if a vote already exists; POST otherwise. Either path
# may be rejected by feature_votes_blocked_on_terminal_feature when the
# parent feature is shipped or declined; surface the platform's
# message verbatim.
if printf '%s' "$existing" | jq -e 'length > 0' >/dev/null; then
  vote_id=$(printf '%s' "$existing" | jq -r '.[0].id')
  body=$(jq -nc \
    --argjson w "$vote_weight" \
    --arg t "$voted_at" \
    '{vote_weight: $w, voted_at: $t}')
  semantius call crud postgrestRequest \
    "{\"method\":\"PATCH\",\"path\":\"/feature_votes?id=eq.${vote_id}\",\"body\":${body}}" >/dev/null \
    || { echo "step 3 (update vote) failed; if code is feature_votes_blocked_on_terminal_feature, the parent feature is shipped or declined and votes are not accepted" >&2; exit 2; }
  echo "cast-vote: updated vote for '$user_email' on '$feature_title' (weight=$vote_weight)"
else
  body=$(jq -nc \
    --arg f "$feature_id" \
    --arg u "$user_id" \
    --argjson w "$vote_weight" \
    --arg t "$voted_at" \
    '{feature_id: $f, user_id: $u, vote_weight: $w, voted_at: $t}')
  semantius call crud postgrestRequest \
    "{\"method\":\"POST\",\"path\":\"/feature_votes\",\"body\":${body}}" >/dev/null \
    || { echo "step 3 (insert vote) failed; if code is feature_votes_blocked_on_terminal_feature, the parent feature is shipped or declined and votes are not accepted" >&2; exit 2; }
  echo "cast-vote: inserted vote for '$user_email' on '$feature_title' (weight=$vote_weight)"
fi
