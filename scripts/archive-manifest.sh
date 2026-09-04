#!/usr/bin/env bash
# archive-manifest.sh  -  the exact file set of a pg_semantius distribution.
#
#   ./scripts/archive-manifest.sh 0.5.0
#     -> one "<source path><TAB><name inside the archive>" pair per line
#
# One definition, three consumers: the release workflow's packaging step,
# release.sh's staging, and pgxn-release.sh's verification of the downloaded
# archive. Keeping them in sync by hand is how a build ends up shipping something
# nobody meant to ship.
#
# The SQL files come from extension/versions.json, NOT from a
# `pg_semantius--*.sql` glob. That is the difference that matters (open item
# B17): pruneOldFullInstalls deliberately keeps anything with a second `--`
# forever, so an upgrade script whose endpoints are no longer in the manifest
# survives regeneration. A glob then packages it, and `make install` hands
# PostgreSQL an `ALTER EXTENSION ... UPDATE` path the manifest knows nothing
# about - permanently, once it reaches PGXN. Driving the list from the manifest
# excludes such a file instead, and `--check` turns it into an error.
#
# With --check, orphans and missing sources are reported on stderr and the exit
# status is 1. Without it, the list is emitted and orphans are silently skipped.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root

VERSION="${1:-}"
CHECK=0
[ "${2:-}" = "--check" ] && CHECK=1
[ -n "$VERSION" ] || { echo "usage: archive-manifest.sh <version> [--check]" >&2; exit 1; }

EXT_DIR="extension"
NAME="pg_semantius"
MANIFEST="$EXT_DIR/versions.json"
[ -f "$MANIFEST" ] || { echo "archive-manifest: $MANIFEST not found" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "archive-manifest: jq is required" >&2; exit 1; }

KNOWN="$(jq -r '.versions | keys_unsorted[]' "$MANIFEST")"
echo "$KNOWN" | grep -qx "$VERSION" \
  || { echo "archive-manifest: $VERSION is not in $MANIFEST (holds: $(echo "$KNOWN" | tr '\n' ' '))" >&2; exit 1; }

fail=0
emit() {                          # emit <source> <archive-name>
  if [ ! -f "$1" ]; then
    echo "archive-manifest: missing source $1" >&2
    fail=1
    return
  fi
  printf '%s\t%s\n' "$1" "$2"
}

# Fixed members. SECURITY.md and LICENSE come from the repo root, everything
# else from extension/.
for f in META.json "$NAME.control" Makefile README.md CHANGES.md; do
  emit "$EXT_DIR/$f" "$f"
done
emit SECURITY.md SECURITY.md
emit LICENSE LICENSE

# The current full install.
emit "$EXT_DIR/$NAME--$VERSION.sql" "$NAME--$VERSION.sql"

# Every upgrade script whose BOTH endpoints the manifest knows. `make install`
# needs the whole chain, so this is not restricted to chains ending at VERSION.
for f in "$EXT_DIR/$NAME--"*"--"*.sql; do
  [ -e "$f" ] || continue
  base="${f##*/}"
  mid="${base#"$NAME--"}"; mid="${mid%.sql}"
  from="${mid%%--*}"
  to="${mid##*--}"
  if echo "$KNOWN" | grep -qx "$from" && echo "$KNOWN" | grep -qx "$to"; then
    emit "$f" "$base"
  else
    echo "archive-manifest: skipping orphaned upgrade script $base ($from and/or $to is not in $MANIFEST)" >&2
    [ "$CHECK" = "1" ] && fail=1
  fi
done

# A full install for a version other than the target should not exist:
# pruneOldFullInstalls removes them. One here means a generation was interrupted.
for f in "$EXT_DIR/$NAME--"*.sql; do
  [ -e "$f" ] || continue
  base="${f##*/}"
  mid="${base#"$NAME--"}"; mid="${mid%.sql}"
  case "$mid" in
    *--*) continue ;;
    "$VERSION") continue ;;
  esac
  echo "archive-manifest: stray full install $base (expected only $NAME--$VERSION.sql)" >&2
  [ "$CHECK" = "1" ] && fail=1
done

exit "$fail"
