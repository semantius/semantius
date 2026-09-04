#!/usr/bin/env bash
# semver.sh  -  semver-correct version comparison for the shell. Source it:
#
#   . "$(dirname "$0")/scripts/semver.sh"
#   semver_valid 0.6.0-rc1        # exit 0 if it is a version we accept
#   semver_cmp 0.6.0-rc1 0.6.0    # prints -1, 0 or 1
#   semver_max 0.6.0-rc1 0.6.0    # prints the higher one
#   ... | semver_max_of           # prints the highest of the lines on stdin
#
# `sort -V` CANNOT be used for this. GNU version sort orders 0.6.0 BEFORE
# 0.6.0-beta, i.e. it treats a pre-release suffix as making the version higher.
# Semver says the opposite and so does every package manager: a pre-release
# precedes its release. Using sort -V would make `release.sh 0.6.0` look like a
# DOWNGRADE from 0.6.0-rc1 and reject the one release you actually want.
#
# The rules implemented (semver.org §11), minus build metadata:
#   - the dotted numeric core compares field by field, missing fields are 0
#   - a version WITHOUT a pre-release is higher than the same core WITH one
#   - two pre-releases compare identifier by identifier, dot separated:
#       numeric identifiers compare numerically and are LOWER than alphanumeric
#       alphanumeric identifiers compare as ASCII
#       if all shared identifiers are equal, fewer identifiers is lower
#
# Build metadata (`+sha`) is rejected rather than ignored: semver says it does
# not affect precedence, which would make two distinct manifest keys compare
# equal, and every guard here is built on a total order.

# Strip a leading `v` and any control characters. The carriage return is the one
# that matters: on Windows jq, git and sed all emit CRLF, so a version read from
# a pipe arrives with a trailing CR, fails the validity pattern, and is silently
# skipped - leaving every caller convinced there are no versions at all. Matched
# as a character class rather than an escape so nothing depends on how this file
# was written. A version never legitimately contains a control character.
_semver_clean() {
  local v="${1#v}"
  printf '%s' "${v//[[:cntrl:]]/}"
}

# A version we accept: dotted numbers, optionally `-` and dot-separated
# alphanumeric identifiers. No `+`, no `--` (the extension filename separator),
# no leading or trailing `-` (PostgreSQL rejects those in an extension version).
semver_valid() {
  local v; v="$(_semver_clean "$1")"
  case "$v" in
    *+*) return 1 ;;
    *--*) return 1 ;;
    *-) return 1 ;;
  esac
  printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
}

# Compare one pre-release identifier. Prints -1, 0 or 1.
_semver_id_cmp() {
  local x="$1" y="$2" xnum=0 ynum=0
  case "$x" in ''|*[!0-9]*) ;; *) xnum=1 ;; esac
  case "$y" in ''|*[!0-9]*) ;; *) ynum=1 ;; esac

  if [ "$xnum" = 1 ] && [ "$ynum" = 1 ]; then
    # Strip leading zeros so 10 > 9 and 007 = 7.
    x=$((10#$x)); y=$((10#$y))
    [ "$x" -gt "$y" ] && { echo 1; return; }
    [ "$x" -lt "$y" ] && { echo -1; return; }
    echo 0; return
  fi
  # Numeric identifiers always have lower precedence than alphanumeric ones.
  [ "$xnum" = 1 ] && { echo -1; return; }
  [ "$ynum" = 1 ] && { echo 1; return; }
  [ "$x" \> "$y" ] && { echo 1; return; }
  [ "$x" \< "$y" ] && { echo -1; return; }
  echo 0
}

semver_cmp() {
  local a b
  a="$(_semver_clean "$1")"
  b="$(_semver_clean "$2")"
  local acore="${a%%-*}" bcore="${b%%-*}"
  local apre="" bpre=""
  case "$a" in *-*) apre="${a#*-}" ;; esac
  case "$b" in *-*) bpre="${b#*-}" ;; esac

  # --- numeric core
  local n i x y
  n=$(( $(printf '%s' "$acore" | tr -cd '.' | wc -c) ))
  i=$(( $(printf '%s' "$bcore" | tr -cd '.' | wc -c) ))
  [ "$i" -gt "$n" ] && n="$i"
  i=0
  while [ "$i" -le "$n" ]; do
    i=$((i + 1))
    x="$(printf '%s' "$acore" | cut -d. -f"$i")"; x="${x:-0}"
    y="$(printf '%s' "$bcore" | cut -d. -f"$i")"; y="${y:-0}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    [ "$x" -gt "$y" ] && { echo 1; return; }
    [ "$x" -lt "$y" ] && { echo -1; return; }
  done

  # --- pre-release presence: no suffix beats a suffix
  [ -z "$apre" ] && [ -z "$bpre" ] && { echo 0; return; }
  [ -z "$apre" ] && { echo 1; return; }
  [ -z "$bpre" ] && { echo -1; return; }

  # --- pre-release identifiers
  local an bn r
  an=$(( $(printf '%s' "$apre" | tr -cd '.' | wc -c) + 1 ))
  bn=$(( $(printf '%s' "$bpre" | tr -cd '.' | wc -c) + 1 ))
  n="$an"; [ "$bn" -gt "$n" ] && n="$bn"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    if [ "$i" -gt "$an" ]; then echo -1; return; fi   # a ran out: fewer is lower
    if [ "$i" -gt "$bn" ]; then echo 1; return; fi
    x="$(printf '%s' "$apre" | cut -d. -f"$i")"
    y="$(printf '%s' "$bpre" | cut -d. -f"$i")"
    r="$(_semver_id_cmp "$x" "$y")"
    [ "$r" != 0 ] && { echo "$r"; return; }
  done
  echo 0
}

# True when the version carries a pre-release suffix.
semver_is_prerelease() {
  local v; v="$(_semver_clean "$1")"
  case "$v" in *-*) return 0 ;; *) return 1 ;; esac
}

# Filter stdin down to final releases (drops pre-releases).
semver_finals() {
  local line
  while IFS= read -r line; do
    line="$(_semver_clean "$line")"
    [ -n "$line" ] || continue
    semver_is_prerelease "$line" && continue
    printf '%s\n' "$line"
  done
}

semver_max() {
  [ "$(semver_cmp "$1" "$2")" = "-1" ] && printf '%s\n' "$2" || printf '%s\n' "$1"
}

# Highest of the versions on stdin, one per line. Invalid lines are skipped.
semver_max_of() {
  local best="" line
  while IFS= read -r line; do
    line="$(_semver_clean "$line")"
    [ -n "$line" ] || continue
    semver_valid "$line" || continue
    if [ -z "$best" ] || [ "$(semver_cmp "$line" "$best")" = "1" ]; then
      best="$line"
    fi
  done
  printf '%s' "$best"
}
