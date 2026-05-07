#!/usr/bin/env bash
# cast-vote.sh: Cast or update a vote on the (feature_id, user_id)
# pair. The feature_votes junction has no DB-level uniqueness, so the
# script reads first and PATCHes if the row exists, POSTs otherwise.
# Composes feature_vote_label as "{user_full_name} -> {feature_title}"
# from the parent rows. Separator is exactly " -> " (space, ASCII
# hyphen, ASCII greater-than, space).
#
# Usage: cast-vote.sh <feature_id> <user_id> [vote_weight]
#        Defaults: vote_weight=1
#        The agent must resolve feature_id and user_id beforehand
#        (e.g. via search_vector=wfts(simple).<term> for features and
#        user_email=eq.<email> for users); ambiguous fuzzy matches are
#        a user-facing question that belongs in the agent, not here.
# Exit:  0 on success
#        1 on usage / precondition failure (bad args, feature or user
#          not found)
#        2 on platform error (a semantius call failed)
#
# Idempotent: rerunning with the same inputs is safe. If a row exists
# the script PATCHes it; a duplicate POST never happens.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $(basename "$0") <feature_id> <user_id> [vote_weight]" >&2
  exit 1
fi

feature_id="$1"
user_id="$2"
vote_weight="${3:-1}"

if ! [[ "$vote_weight" =~ ^-?[0-9]+$ ]]; then
  echo "Invalid vote_weight '$vote_weight'; expected integer" >&2
  exit 1
fi

# Step 1: read both parents to compose the label and confirm they
# exist. No dependency between these reads.
# expect: --single per read; exit 1 from semantius means zero rows
#         (parent missing) or multiple rows (impossible on id=eq.).
feature_row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id,feature_title\"}") \
  || { echo "step 1: feature $feature_id not found; ask the user for the correct feature title" >&2; exit 1; }
user_row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/users?id=eq.$user_id&select=id,user_full_name\"}") \
  || { echo "step 1: user $user_id not found; ask the user to create the user first via use-semantius" >&2; exit 1; }

# --single returns a bare object, so no head -n1 / [0] indexing.
feature_title=$(printf '%s' "$feature_row" | grep -oE '"feature_title":"[^"]*"' | sed 's/"feature_title":"\(.*\)"/\1/')
user_full_name=$(printf '%s' "$user_row" | grep -oE '"user_full_name":"[^"]*"' | sed 's/"user_full_name":"\(.*\)"/\1/')

label="$user_full_name -> $feature_title"
label_json=$(printf '%s' "$label" | sed 's/\\/\\\\/g; s/"/\\"/g')

voted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Step 2: dedupe lookup; depends on feature_id + user_id.
# expect: array (zero or one row); zero is the "POST new" branch,
#         one is the "PATCH existing" branch.
existing=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/feature_votes?feature_id=eq.$feature_id&user_id=eq.$user_id&select=id,vote_weight\"}") \
  || { echo "step 2 (read existing feature_votes) failed" >&2; exit 2; }

existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\(.*\)"/\1/')

if [ -n "$existing_id" ]; then
  # Step 3a: PATCH existing row. Refresh weight, voted_at, and label.
  # expect: array (write returns the patched row); exit-code guard only.
  semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/feature_votes?id=eq.$existing_id\",\"body\":{\"vote_weight\":$vote_weight,\"voted_at\":\"$voted_at\",\"feature_vote_label\":\"$label_json\"}}" \
    >/dev/null \
    || { echo "step 3 (PATCH feature_vote $existing_id) failed" >&2; exit 2; }
  echo "cast-vote: ok (updated existing vote $existing_id; weight=$vote_weight)"
else
  # Step 3b: POST new row.
  # expect: array (write returns the inserted row); exit-code guard only.
  semantius call crud postgrestRequest "{\"method\":\"POST\",\"path\":\"/feature_votes\",\"body\":{\"feature_vote_label\":\"$label_json\",\"feature_id\":\"$feature_id\",\"user_id\":\"$user_id\",\"vote_weight\":$vote_weight,\"voted_at\":\"$voted_at\"}}" \
    >/dev/null \
    || { echo "step 3 (POST feature_vote) failed" >&2; exit 2; }
  echo "cast-vote: ok (cast new vote; weight=$vote_weight)"
fi
