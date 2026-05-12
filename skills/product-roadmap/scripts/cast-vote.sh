#!/usr/bin/env bash
# cast-vote.sh: Cast or update a vote on a feature for a user. The
# (feature_id, user_id) pair has no DB-level uniqueness, so the recipe
# reads first and either INSERTs or PATCHes the existing row.
#
# Usage: cast-vote.sh <feature-title> <user-email> [<weight>]
#
# Exit:  0 on success
#        1 on usage / validation failure (bad args, unresolved title or email,
#          weight < 1, duplicate junction rows already exist)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same (title, email, weight) produces a
# deterministic no-op the second time, the existing row is found and
# PATCHed to the same weight.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <feature-title> <user-email> [<weight>]" >&2
  exit 1
fi

feature_title="$1"
user_email="$2"
weight="${3:-1}"
voted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Step 1: parallel-fetch (no dependency between these reads)
feature=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${feature_title// /%20}&select=id,feature_title\"}") \
  || { echo "step 1a: feature '$feature_title' not found or ambiguous" >&2; exit 1; }
user=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/users?user_email=eq.$user_email&select=id,user_full_name,user_status\"}") \
  || { echo "step 1b: user '$user_email' not found" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
ft_safe=$(printf '%s' "$feature" | grep -oE '"feature_title":"[^"]+"' | head -n1 | cut -d'"' -f4)
user_id=$(printf '%s' "$user" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
ufn=$(printf '%s' "$user" | grep -oE '"user_full_name":"[^"]+"' | head -n1 | cut -d'"' -f4)
ustatus=$(printf '%s' "$user" | grep -oE '"user_status":"[^"]+"' | head -n1 | cut -d'"' -f4)

if [ "$ustatus" = "inactive" ]; then
  echo "warning: user '$user_email' is inactive; proceeding anyway" >&2
fi

label="$ufn -> $ft_safe"

# Step 2: dedupe the junction
existing=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/feature_votes?feature_id=eq.$feature_id&user_id=eq.$user_id&select=id\"}") \
  || { echo "step 2: dedupe read failed" >&2; exit 2; }

count=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | wc -l | tr -d ' ')

if [ "$count" -gt 1 ]; then
  echo "step 2: $count duplicate feature_votes rows exist for (feature='$feature_title', user='$user_email'); clean up the duplicates manually before retrying" >&2
  exit 1
fi

if [ "$count" -eq 1 ]; then
  existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
  semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/feature_votes?id=eq.$existing_id\",\"body\":{\"vote_weight\":$weight,\"voted_at\":\"$voted_at\",\"feature_vote_label\":\"$label\"}}" \
    || { echo "step 3: PATCH /feature_votes failed; if platform returned vote_weight_positive, weight was < 1; surface verbatim" >&2; exit 2; }
else
  semantius call crud postgrestRequest "{\"method\":\"POST\",\"path\":\"/feature_votes\",\"body\":{\"feature_id\":\"$feature_id\",\"user_id\":\"$user_id\",\"vote_weight\":$weight,\"voted_at\":\"$voted_at\",\"feature_vote_label\":\"$label\"}}" \
    || { echo "step 3: POST /feature_votes failed; if platform returned vote_weight_positive, weight was < 1; surface verbatim" >&2; exit 2; }
fi

verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/feature_votes?feature_id=eq.$feature_id&user_id=eq.$user_id&select=id,vote_weight,feature_vote_label\"}") \
  || { echo "step 4: verify read failed" >&2; exit 2; }

echo "cast-vote: ok"
printf '%s\n' "$verify"
