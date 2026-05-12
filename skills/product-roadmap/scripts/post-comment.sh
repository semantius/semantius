#!/usr/bin/env bash
# post-comment.sh: Post a comment on a feature, composing the
# `comment_label` deterministically from the body. The author is
# required on insert (platform-enforced via author_required_on_insert).
#
# Usage: post-comment.sh <feature-title> <user-email> <comment-body>
#
# Exit:  0 on success
#        1 on usage / validation failure (bad args, unresolved title or email,
#          empty body)
#        2 on platform error (semantius call failed)
#
# Label composition: first 80 chars of comment_body. If the cut falls
# mid-word (char 80 is not a space and char 81 exists and is not a
# space), retract to the last space at or before position 80. If the
# body was longer than the cut, append the literal '…' (U+2026); no
# trailing space. If the body is <= 80 chars, the label is the body
# verbatim.
#
# Idempotent: comments are append-only; re-running posts another
# comment. The script does not dedupe; that is by design.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $(basename "$0") <feature-title> <user-email> <comment-body>" >&2
  exit 1
fi

feature_title="$1"
user_email="$2"
shift 2
body="$*"
posted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Trim leading/trailing whitespace
body_trimmed="$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ -z "$body_trimmed" ]; then
  echo "step 0: comment_body is empty after trimming whitespace" >&2
  exit 1
fi

# Compose label
body_len=${#body_trimmed}
if [ "$body_len" -le 80 ]; then
  label="$body_trimmed"
else
  cut="${body_trimmed:0:80}"
  next_char="${body_trimmed:80:1}"
  last_char="${cut: -1}"
  if [ "$last_char" != " " ] && [ "$next_char" != " " ]; then
    # mid-word; retract to last space at or before position 80
    cut="${cut% *}"
    if [ "$cut" = "${body_trimmed:0:80}" ]; then
      # no space in the first 80 chars; keep the hard cut
      cut="${body_trimmed:0:80}"
    fi
  fi
  # strip trailing whitespace from cut
  cut="$(printf '%s' "$cut" | sed -e 's/[[:space:]]*$//')"
  label="${cut}…"
fi

# Step 1: parallel-fetch
feature=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?search_vector=wfts(simple).${feature_title// /%20}&select=id,feature_title\"}") \
  || { echo "step 1a: feature '$feature_title' not found or ambiguous" >&2; exit 1; }
user=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/users?user_email=eq.$user_email&select=id\"}") \
  || { echo "step 1b: user '$user_email' not found" >&2; exit 1; }

feature_id=$(printf '%s' "$feature" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
author_id=$(printf '%s' "$user" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)

# Step 2: POST. Escape backslashes and double-quotes for JSON.
body_json=$(printf '%s' "$body_trimmed" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
label_json=$(printf '%s' "$label" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

response=$(semantius call crud postgrestRequest "{\"method\":\"POST\",\"path\":\"/comments\",\"body\":{\"feature_id\":\"$feature_id\",\"author_id\":\"$author_id\",\"comment_body\":\"$body_json\",\"comment_label\":\"$label_json\",\"posted_at\":\"$posted_at\"}}") \
  || { echo "step 2: POST /comments failed; if author_required_on_insert was returned, the user lookup leaked through; surface the platform code verbatim" >&2; exit 2; }

new_id=$(printf '%s' "$response" | grep -oE '"id":"[^"]+"' | head -n1 | cut -d'"' -f4)
if [ -z "$new_id" ]; then
  echo "step 2: POST /comments returned no id" >&2
  exit 2
fi

verify=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/comments?id=eq.$new_id&select=id,comment_label,feature_id,author_id\"}") \
  || { echo "step 3: verify read failed" >&2; exit 2; }

echo "post-comment: ok"
printf '%s\n' "$verify"
