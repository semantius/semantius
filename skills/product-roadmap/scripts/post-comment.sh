#!/usr/bin/env bash
# post-comment.sh: POST a comment on a feature. Composes comment_label
# deterministically from comment_body: if body is at most 80 chars,
# label=body verbatim; otherwise the first 80 chars are cut at the
# last whitespace position when one exists in the prefix (else cut
# mid-word), trailing whitespace is stripped, and the Unicode
# horizontal ellipsis (U+2026) is appended. The body is left intact
# in comment_body.
#
# Usage: post-comment.sh <feature_id> <author_id> <comment_body>
#        comment_body is one positional argument; the caller must
#        quote it if it contains spaces or special characters.
# Exit:  0 on success
#        1 on usage / precondition failure (bad args, empty body,
#          feature or author not found)
#        2 on platform error (a semantius call failed)
#
# NOT idempotent: every run POSTs a new row. Comments are append-only
# by design; the caller must guard against accidental retries.
#
# Locale: requires a UTF-8 locale (LC_ALL=C.UTF-8 or similar) so that
# awk's length() and substr() count characters rather than bytes when
# the body contains non-ASCII text.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $(basename "$0") <feature_id> <author_id> <comment_body>" >&2
  exit 1
fi

feature_id="$1"
author_id="$2"
body="$3"

if [ -z "$body" ]; then
  echo "step 0: comment_body must not be empty" >&2
  exit 1
fi

# Step 1: confirm both parents exist. No dependency between these
# reads; bash sequences them but each is cheap.
# expect: --single per read; exit 1 from semantius means the parent
#         is missing (zero rows) or ambiguous (impossible on id=eq.).
semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id\"}" \
  >/dev/null \
  || { echo "step 1: feature $feature_id not found" >&2; exit 1; }

semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/users?id=eq.$author_id&select=id\"}" \
  >/dev/null \
  || { echo "step 1: author $author_id not found" >&2; exit 1; }

# Step 2: compose comment_label. The awk program counts characters
# under a UTF-8 locale and emits the U+2026 ellipsis as its three
# UTF-8 bytes when truncation occurred.
label=$(LC_ALL=C.UTF-8 awk -v body="$body" 'BEGIN{
  n = length(body)
  if (n <= 80) { printf "%s", body; exit }
  prefix = substr(body, 1, 80)
  next_char = substr(body, 81, 1)
  last_char = substr(prefix, 80, 1)
  if (next_char ~ /[[:space:]]/ || last_char ~ /[[:space:]]/) {
    sub(/[[:space:]]+$/, "", prefix)
    printf "%s\xe2\x80\xa6", prefix
    exit
  }
  for (i = 79; i >= 1; i--) {
    if (substr(prefix, i, 1) ~ /[[:space:]]/) {
      cut = substr(prefix, 1, i-1)
      sub(/[[:space:]]+$/, "", cut)
      printf "%s\xe2\x80\xa6", cut
      exit
    }
  }
  printf "%s\xe2\x80\xa6", prefix
}')

# Escape JSON-special characters in label and body. The body may
# contain newlines; collapse them to \n.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g'
}
label_json=$(json_escape "$label")
body_json=$(json_escape "$body")

posted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Step 3: POST.
# expect: array (write returns the inserted row); exit-code guard only.
semantius call crud postgrestRequest "{\"method\":\"POST\",\"path\":\"/comments\",\"body\":{\"comment_label\":\"$label_json\",\"feature_id\":\"$feature_id\",\"author_id\":\"$author_id\",\"comment_body\":\"$body_json\",\"posted_at\":\"$posted_at\"}}" \
  >/dev/null \
  || { echo "step 3 (POST comment) failed" >&2; exit 2; }

echo "post-comment: ok"
