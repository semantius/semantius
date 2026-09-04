#!/usr/bin/env bash
# pgxn-release.sh  -  publish a released version to PGXN. Deliberately NOT in CI.
#
#   ./scripts/pgxn-release.sh v0.5.0            # verify, show the result, then ask
#   ./scripts/pgxn-release.sh v0.5.0 --confirm  # skip the prompt (non-interactive)
#
# The argument is the tag; a bare 0.5.0 is accepted too.
#
# It uploads THE ARCHIVE ATTACHED TO THE GITHUB RELEASE, downloaded with `gh`,
# never a locally rebuilt one. Two reasons: what gets frozen on PGXN is then the
# same bytes everyone else already downloaded, and it removes the dependency on
# `zip`, which is not installed on the maintainer's machine.
#
# PGXN is the one channel this project cannot take back. A GitHub Release is
# deleted and recreated on every re-release and a GHCR tag is overwritten, which
# is what makes the newest version mutable. A PGXN release is permanent: a
# version can never be replaced or withdrawn, only superseded by a higher one.
# So this is separate, manual and guarded - never a workflow, never a side effect
# of tagging. Publish only when the version is FINAL.
#
# See RELEASE.md.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root

NAME="pg_semantius"
EXT_DIR="extension"

die() { echo "pgxn-release: $*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
VERSION=""
CONFIRM=0
ALLOW_TESTING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm)              CONFIRM=1 ;;
    --allow-testing-release) ALLOW_TESTING=1 ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$VERSION" ] || die "unexpected argument: $1 (one version only)"
      VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || die "a version is required, e.g. ./scripts/pgxn-release.sh v0.5.0"
# The tag is `v<version>`; the archive, META.json and the SQL filenames use the
# bare version. Accept either spelling.
VERSION="${VERSION#v}"

# ---------------------------------------------------------------- tools
command -v gh >/dev/null 2>&1 || die "gh is required: this script publishes the
  artifact FROM the GitHub Release, not a local rebuild. Install
  https://cli.github.com and run 'gh auth login'. There is deliberately no
  local-rebuild fallback - a locally built zip is not the artifact anyone
  downloaded, and PGXN is permanent."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

UNZIP=""
if command -v unzip >/dev/null 2>&1; then
  UNZIP="unzip"
elif command -v python3 >/dev/null 2>&1; then
  UNZIP="python3"
else
  die "neither unzip nor python3 is available to inspect the archive"
fi

# ---------------------------------------------------------------- local state
[ -z "$(git status --porcelain)" ] \
  || die "the working tree is dirty; commit or stash before publishing"

git fetch --tags --force --quiet origin 2>/dev/null || true
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
  || die "tag v$VERSION does not exist locally - release it first (./release.sh $VERSION --confirm)"

LOCAL_TAG_SHA="$(git rev-parse "v$VERSION^{commit}")"
REMOTE_TAG_SHA="$(git ls-remote origin "refs/tags/v$VERSION^{}" | cut -f1)"
[ -n "$REMOTE_TAG_SHA" ] || REMOTE_TAG_SHA="$(git ls-remote origin "refs/tags/v$VERSION" | cut -f1)"
[ "$LOCAL_TAG_SHA" = "$REMOTE_TAG_SHA" ] \
  || die "local tag v$VERSION ($LOCAL_TAG_SHA) does not match origin ($REMOTE_TAG_SHA); push it first"

[ "$LOCAL_TAG_SHA" = "$(git rev-parse HEAD)" ] \
  || die "HEAD is not the commit tagged v$VERSION; check out that tag first"

INSTALL="$EXT_DIR/$NAME--$VERSION.sql"
[ -f "$INSTALL" ] || die "$INSTALL not found - generate it first"

META_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXT_DIR/META.json")"
[ "$META_VERSION" = "$VERSION" ] || die "$EXT_DIR/META.json is version $META_VERSION, not $VERSION"

CONTROL_VERSION="$(sed -nE "s/^default_version = '(.*)'/\1/p" "$EXT_DIR/$NAME.control")"
[ "$CONTROL_VERSION" = "$VERSION" ] || die "$NAME.control default_version is $CONTROL_VERSION, not $VERSION"

# The build on disk must be what the generator produces from these sources -
# the same oracle CI uses (git status after a regeneration), rather than a
# temp-directory diff. It regenerates IN PLACE, and pruneOldFullInstalls deletes
# files, so restore extension/ on any exit.
echo "Verifying the local build is reproducible..."
trap 'git checkout -- "$EXT_DIR" 2>/dev/null || true' EXIT
deno task extension "$VERSION" >/dev/null
[ -z "$(git status --porcelain -- "$EXT_DIR")" ] \
  || die "$EXT_DIR/ differs from a fresh regeneration; re-release before publishing to PGXN"
trap - EXIT

# ---------------------------------------------------------------- the artifact
REPO="$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
ZIPNAME="$NAME-$VERSION.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading $ZIPNAME from the v$VERSION release of $REPO..."
gh release download "v$VERSION" --repo "$REPO" --pattern "$ZIPNAME" --dir "$WORK" \
  || die "no release asset $ZIPNAME for tag v$VERSION - push the tag and let
  .github/workflows/extension-release.yml publish it first"
ZIP="$WORK/$ZIPNAME"

list_zip() {
  if [ "$UNZIP" = "unzip" ]; then
    unzip -Z1 "$ZIP"
  else
    python3 -c 'import sys,zipfile;print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$ZIP"
  fi
}
cat_zip() {                       # cat_zip <path-inside-zip>
  if [ "$UNZIP" = "unzip" ]; then
    unzip -p "$ZIP" "$1"
  else
    python3 -c 'import sys,zipfile;sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$ZIP" "$1"
  fi
}

DIST="$NAME-$VERSION"
TOPS="$(list_zip | sed 's#/.*##' | sort -u)"
[ "$TOPS" = "$DIST" ] \
  || die "the archive must unpack into a single $DIST/ directory, found: $(echo "$TOPS" | tr '\n' ' ')"

# The expected file set, from extension/versions.json - the same list the
# workflow packaged from. Comparing the archive against a glob of extension/
# would agree with itself about an orphaned upgrade script; comparing against
# the manifest is what catches one.
bash scripts/archive-manifest.sh "$VERSION" --check > "$WORK/manifest.txt" \
  || die "the expected file set is not clean; fix it and re-release before publishing"

ARCHIVE_FILES="$(list_zip | sed "s#^$DIST/##" | grep -v '^$' | sort)"
EXPECTED_FILES="$(cut -f2 "$WORK/manifest.txt" | sort)"
if [ "$ARCHIVE_FILES" != "$EXPECTED_FILES" ]; then
  echo "archive contents differ from the expected set:" >&2
  diff <(echo "$EXPECTED_FILES") <(echo "$ARCHIVE_FILES") >&2 || true
  die "refusing to publish an archive whose file set is not the manifest's"
fi

# Content. Both sides through `tr -d '\r'`: the archive was built on a Linux
# runner from LF blobs, while a fresh clone of this repo has core.autocrlf=true
# and no .gitattributes, so the text files here can be CRLF. That makes this a
# content comparison, not a literal byte comparison.
while IFS="$(printf '\t')" read -r src name; do
  if ! diff -q <(tr -d '\r' < "$src") <(cat_zip "$DIST/$name" | tr -d '\r') >/dev/null; then
    die "archive member $name differs from $src"
  fi
done < "$WORK/manifest.txt"

# The manifest PGXN will actually ingest is the one inside the archive.
mkdir -p "$WORK/x"
cat_zip "$DIST/META.json"   > "$WORK/x/META.json"
cat_zip "$DIST/CHANGES.md"  > "$WORK/x/CHANGES.md"
cat_zip "$DIST/$NAME--$VERSION.sql" > "$WORK/x/$NAME--$VERSION.sql"
bash scripts/check-pgxn-meta.sh "$WORK/x/META.json"

RELEASE_STATUS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("release_status",""))' "$WORK/x/META.json")"
if [ "$RELEASE_STATUS" != "stable" ] && [ "$ALLOW_TESTING" != "1" ]; then
  die "META.json release_status is '$RELEASE_STATUS', not 'stable'.
  PGXN keeps whatever you upload forever, so publishing a build you still intend
  to change is exactly what this channel cannot undo. The generator hardcodes
  'testing' - change it there first, or pass --allow-testing-release if a
  testing release is genuinely what you want."
fi

# ---------------------------------------------------------------- confirm
# Everything above has already run, so the decision is made with the results in
# view. --confirm skips the prompt for non-interactive use; typing the version is
# asked for instead of y/N because this one cannot be undone.
SUM="$(sha256sum "$ZIP" | cut -d' ' -f1)"
cat >&2 <<EOF

Verified. About to publish $NAME $VERSION to PGXN.

  archive        $ZIPNAME
  sha256         $SUM
  release        https://github.com/$REPO/releases/tag/v$VERSION
  release_status $RELEASE_STATUS

  This CANNOT be undone. PGXN releases are permanent: the version can never be
  replaced or withdrawn, only superseded. After this, v$VERSION is frozen
  everywhere - stop re-releasing it and cut the next version for any change.

EOF

if [ "$CONFIRM" != "1" ]; then
  if [ ! -t 0 ]; then
    die "not a terminal, so there is nobody to ask. Re-run with --confirm."
  fi
  printf 'Type the version to publish it permanently (or anything else to cancel): ' >&2
  read -r answer
  if [ "$answer" != "$VERSION" ]; then
    echo "Canceled. Nothing was uploaded." >&2
    exit 0
  fi
fi

# ---------------------------------------------------------------- upload
if command -v pgxn >/dev/null 2>&1; then
  echo "Uploading $ZIPNAME to PGXN..."
  pgxn release "$ZIP"
  echo "Done. $NAME $VERSION is now permanent on PGXN."
else
  KEEP="$(pwd)/$ZIPNAME"
  cp "$ZIP" "$KEEP"
  cat <<EOF

NOT UPLOADED - the pgxn client is not installed.

  Everything was verified. Upload the archive by hand:
    1. https://manager.pgxn.org/upload
    2. select $KEEP

  Or install the client and re-run:  gem install pgxn_utils

EOF
fi
