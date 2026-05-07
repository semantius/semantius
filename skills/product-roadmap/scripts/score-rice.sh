#!/usr/bin/env bash
# score-rice.sh: Update one or more RICE inputs on a feature and
# recompute features.rice_score in the same PATCH. Round to 4 decimals
# (numeric scale 4). If post-overlay effort_score is null or zero,
# write rice_score=null instead of a placeholder.
#
# Usage: score-rice.sh <feature_id> [reach=<n>] [impact=<n>] [confidence=<n>] [effort=<n>]
#        At least one of reach/impact/confidence/effort must be provided.
# Exit:  0 on success
#        1 on usage / precondition failure (bad args, no inputs given,
#          feature not found)
#        2 on platform error (a semantius call failed)
#
# Idempotent: rerunning with the same inputs is safe; the PATCH writes
# the same final values whether the script ran before or not.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $(basename "$0") <feature_id> [reach=<n>] [impact=<n>] [confidence=<n>] [effort=<n>]" >&2
  exit 1
fi

feature_id="$1"
shift

reach_in=""
impact_in=""
confidence_in=""
effort_in=""
for kv in "$@"; do
  case "$kv" in
    reach=*)      reach_in="${kv#reach=}" ;;
    impact=*)     impact_in="${kv#impact=}" ;;
    confidence=*) confidence_in="${kv#confidence=}" ;;
    effort=*)     effort_in="${kv#effort=}" ;;
    *) echo "Unknown arg '$kv'; expected reach=, impact=, confidence=, effort=" >&2; exit 1 ;;
  esac
done

if [ -z "${reach_in}${impact_in}${confidence_in}${effort_in}" ]; then
  echo "step 0: at least one of reach=, impact=, confidence=, effort= must be provided" >&2
  exit 1
fi

# Step 1: read current scores. Need them to overlay caller deltas
# before recomputing rice_score.
# expect: --single; exit 1 from semantius means feature not found.
row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/features?id=eq.$feature_id&select=id,reach_score,impact_score,confidence_score,effort_score\"}") \
  || { echo "step 1: feature $feature_id not found; ask the user for the correct feature title" >&2; exit 1; }

# --single returns a bare object; no head -n1 / [0] indexing.
extract_num() {
  printf '%s' "$row" | grep -oE "\"$1\":(null|-?[0-9]+(\\.[0-9]+)?)" | sed -E "s/.*:(null|-?[0-9]+(\\.[0-9]+)?)/\\1/"
}

reach_cur=$(extract_num reach_score)
impact_cur=$(extract_num impact_score)
confidence_cur=$(extract_num confidence_score)
effort_cur=$(extract_num effort_score)

reach="${reach_in:-$reach_cur}"
impact="${impact_in:-$impact_cur}"
confidence="${confidence_in:-$confidence_cur}"
effort="${effort_in:-$effort_cur}"

# Step 2: compute rice_score. Set null if any input is null/empty or
# effort is zero.
rice="null"
if [ -n "$reach" ] && [ "$reach" != "null" ] \
   && [ -n "$impact" ] && [ "$impact" != "null" ] \
   && [ -n "$confidence" ] && [ "$confidence" != "null" ] \
   && [ -n "$effort" ] && [ "$effort" != "null" ]; then
  effort_zero=$(awk -v e="$effort" 'BEGIN{ print (e+0 == 0) ? "1" : "0" }')
  if [ "$effort_zero" = "0" ]; then
    rice=$(awk -v r="$reach" -v i="$impact" -v c="$confidence" -v e="$effort" 'BEGIN{ printf "%.4f", (r*i*c)/e }')
  fi
fi

# Step 3: build PATCH body. Include only the input fields the caller
# named, plus the recomputed rice_score.
body="{"
sep=""
for pair in "reach_score:$reach_in" "impact_score:$impact_in" "confidence_score:$confidence_in" "effort_score:$effort_in"; do
  key="${pair%%:*}"
  val="${pair#*:}"
  if [ -n "$val" ]; then
    body="${body}${sep}\"${key}\":${val}"
    sep=","
  fi
done
if [ "$rice" = "null" ]; then
  body="${body}${sep}\"rice_score\":null"
else
  body="${body}${sep}\"rice_score\":${rice}"
fi
body="${body}}"

# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest "{\"method\":\"PATCH\",\"path\":\"/features?id=eq.$feature_id\",\"body\":${body}}" \
  >/dev/null \
  || { echo "step 3 (PATCH feature $feature_id with new RICE inputs) failed" >&2; exit 2; }

if [ "$rice" = "null" ]; then
  echo "score-rice: ok (feature $feature_id; rice_score=null because effort_score is null/zero)"
else
  echo "score-rice: ok (feature $feature_id; rice_score=$rice)"
fi
