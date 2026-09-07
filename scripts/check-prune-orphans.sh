#!/usr/bin/env bash
# check-prune-orphans.sh  -  the extension generator deletes upgrade scripts the
# manifest does not account for.
#
#   ./scripts/check-prune-orphans.sh            # version from the control file
#   ./scripts/check-prune-orphans.sh 0.5.0-beta1
#
# What it protects. `make install` copies whatever SQL sits in the build
# directory, and PostgreSQL then offers every `<from>--<to>` pair it finds as an
# `ALTER EXTENSION ... UPDATE` path. A file whose endpoints are not in
# `extension/versions.json` is a path nobody generated a migration set for, and
# nothing downstream can tell it from a real one. It needs no mistake to appear:
# discarding version history orphans the whole chain, which is what resetting the
# manifest for 0.5.0 did to the 0.3.0 and 0.4.0 scripts.
#
# `scripts/archive-manifest.sh --check` catches the same file on the release
# path. This runs on every pull request and on any developer's disk, before an
# orphan can reach a locally built image: both Dockerfiles copy the SQL by glob.
#
# Method: regenerate into a COPY of extension/ with two fabricated orphans in
# it, one with an unknown `<from>` and one with an unknown `<to>`, and assert
# both are gone and the real build is still there. The copy brings versions.json
# along, so the frozen-version guard sees the target as the newest build and
# lets it be regenerated. Nothing outside --output is written, so the real
# extension/ is untouched.
#
# The keep-case - a live chain whose endpoints ARE in the manifest - cannot be
# exercised while the manifest holds a single version. It becomes testable when
# a second version exists.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root

NAME="pg_semantius"
SRC="extension"
CONTROL="$SRC/$NAME.control"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(sed -nE "s/^default_version = '(.*)'/\1/p" "$CONTROL")"
  [ -n "$VERSION" ] || { echo "check-prune-orphans: no default_version in $CONTROL" >&2; exit 1; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp -r "$SRC/." "$TMP/"

ORPHAN_FROM="$NAME--0.4.0--$VERSION.sql"     # <from> is not a manifest version
ORPHAN_TO="$NAME--$VERSION--9.9.9.sql"       # <to> is not a manifest version
for f in "$ORPHAN_FROM" "$ORPHAN_TO"; do
  printf -- '-- fabricated by check-prune-orphans.sh\n' > "$TMP/$f"
done

echo "check-prune-orphans: regenerating $VERSION into $TMP"
deno task --quiet extension "$VERSION" --output "$TMP" > "$TMP/.generator.log" 2>&1 || {
  echo "check-prune-orphans: the generator failed:" >&2
  cat "$TMP/.generator.log" >&2
  exit 1
}

fail=0
for f in "$ORPHAN_FROM" "$ORPHAN_TO"; do
  if [ -e "$TMP/$f" ]; then
    echo "check-prune-orphans: $f survived regeneration; its endpoints are not in versions.json" >&2
    fail=1
  fi
done

# Without these the check would pass just as well on a generator that deleted
# everything, or on one that failed before writing anything.
for f in "$NAME--$VERSION.sql" "$NAME.control" "versions.json"; do
  if [ ! -e "$TMP/$f" ]; then
    echo "check-prune-orphans: $f is missing from the regenerated build" >&2
    fail=1
  fi
done

if [ "$fail" = "0" ]; then
  echo "check-prune-orphans: both orphaned upgrade scripts were pruned, the build is intact"
fi
exit "$fail"
