#!/usr/bin/env bash
# release.sh  -  build and release one version of the Semantius extension.
#
#   ./release.sh 0.5.0                 # dry run: decide, preflight, explain, stop
#   ./release.sh 0.5.0 --confirm       # do it
#
# The version argument decides everything:
#
#   lower than the current build   ->  rejected, immediately
#   equal to the current build     ->  refresh the artifacts (a re-release)
#   higher                         ->  build a new version (+ an upgrade script)
#
# "Current" is the highest version in extension/versions.json - the manifest is
# what the generator's own frozen-version guard reads, and a version is built
# before it is ever tagged. The git tags are cross-checked: a tag ABOVE the
# manifest means something was published that the manifest cannot see, and every
# guard downstream is then blind, so that is refused.
#
# WHAT THIS SCRIPT DOES NOT DO: publish. No `gh release create`, no `docker push`,
# no PGXN. It verifies, commits, tags and pushes; pushing the tag starts
# .github/workflows/extension-release.yml, which publishes the GitHub Release and
# the GHCR image. PGXN is a separate manual step, ./scripts/pgxn-release.sh, run
# after the GitHub Release exists.
#
# The duplication with CI is deliberate and is the whole design: the harnesses run
# HERE to prove the current working tree is green, and CI re-runs them from a
# clean checkout to prove the result is REPRODUCIBLE rather than green only on
# this machine. The porcelain guard is that same check for the artifacts.
#
# See plans/release-script.md for the reasoning, RELEASE.md for the rules.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

NAME="pg_semantius"
EXT_DIR="extension"
MANIFEST="$EXT_DIR/versions.json"

die() { echo "release.sh: $*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
TARGET=""
CONFIRM=0
SKIP_TESTS=0
NO_IMAGE=0
ALLOW_EDITED=0
RERUN_CI=0

while [ $# -gt 0 ]; do
  case "$1" in
    --confirm)                  CONFIRM=1 ;;
    --skip-tests)               SKIP_TESTS=1 ;;
    --no-image)                 NO_IMAGE=1 ;;
    --allow-edited-migrations)  ALLOW_EDITED=1 ;;
    --rerun-ci)                 RERUN_CI=1 ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "unknown option: $1 (see ./release.sh --help)" ;;
    *)
      [ -z "$TARGET" ] || die "unexpected argument: $1 (one version only)"
      TARGET="$1" ;;
  esac
  shift
done

[ -n "$TARGET" ] || die "a version is required, e.g. ./release.sh 0.5.0 --confirm"

# Dotted numbers only. compareVersions() in the generator does split(".") + Number,
# so a suffix like -rc1 yields NaN and silently disables the frozen-version guard.
case "$TARGET" in
  *[!0-9.]* | .* | *. | "") die "invalid version \"$TARGET\": dotted numbers only (1.2.3)" ;;
esac

# ==========================================================================
# Phase 0 - decide. No side effects: the reject case must be instant.
# ==========================================================================
command -v jq >/dev/null 2>&1 || die "jq is required (it reads $MANIFEST)"
[ -f "$MANIFEST" ] || die "$MANIFEST not found - is this the repo root?"

# jq, not grep: the per-migration keys inside `files` sit at the same nesting
# depth as the version keys and a pattern match would pick them up too.
CURRENT="$(jq -r '.versions | keys_unsorted[]' "$MANIFEST" | sort -V | tail -1)"
[ -n "$CURRENT" ] || die "$MANIFEST holds no versions"

ver_max() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }

if [ "$TARGET" = "$CURRENT" ]; then
  MODE=refresh
elif [ "$(ver_max "$TARGET" "$CURRENT")" = "$TARGET" ]; then
  MODE=new
else
  cat >&2 <<EOF
release.sh: $TARGET is lower than the current build $CURRENT.

  A superseded version is frozen. Regenerating it would delete the $CURRENT full
  install, orphan its upgrade script and move default_version backwards, and the
  generator refuses it for the same reason.

  To re-release the current build:  ./release.sh $CURRENT --confirm
  To cut a new one:                 ./release.sh <higher version> --confirm
EOF
  exit 1
fi

# The manifest knows what was BUILT; the tags record what was PUBLISHED. A tag
# above the manifest means a published version the manifest cannot see, which
# blinds the frozen-version guard - refuse rather than guess.
git fetch --tags --force --quiet 2>/dev/null || true
TOP_TAG="$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1)"
if [ -n "$TOP_TAG" ] && [ "$TOP_TAG" != "$CURRENT" ] && \
   [ "$(ver_max "$TOP_TAG" "$CURRENT")" = "$TOP_TAG" ]; then
  die "tag v$TOP_TAG is above the newest build $CURRENT in $MANIFEST.
  Something was published that the manifest does not know about, so the
  frozen-version guard cannot protect it. Reconcile before releasing."
fi

echo "== release.sh: $TARGET ($MODE; current build $CURRENT, highest tag ${TOP_TAG:-none}) =="

# ==========================================================================
# Phase 1 - read-only preflight. Accumulate, so one dry run shows every
# blocker instead of one per invocation.
# ==========================================================================
fail_n=0
bad() { echo "  FAIL  $*" >&2; fail_n=$((fail_n + 1)); }
ok()  { echo "  ok    $*"; }

echo
echo "== [1/8] Preflight =="

for t in deno docker git jq; do
  command -v "$t" >/dev/null 2>&1 && ok "$t present" || bad "$t is not installed"
done

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "HEAD" ]; then
  bad "detached HEAD; check out a branch"
else
  ok "on branch $BRANCH"
fi

UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -z "$UPSTREAM" ]; then
  bad "$BRANCH has no upstream; the push at the end would fail"
else
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  BEHIND="$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
  [ "$BEHIND" = "0" ] && ok "up to date with $UPSTREAM" \
    || bad "$BEHIND commit(s) behind $UPSTREAM; pull first"
fi

# All paths, no exceptions: "the tag points at exactly what was tested" is the
# property everything else rests on. release.sh commits only what it generates.
if [ -z "$(git status --porcelain)" ]; then
  ok "working tree clean"
else
  git status --porcelain >&2
  bad "working tree is dirty; commit your source changes first"
fi

if grep -q "^## $TARGET\$" "$EXT_DIR/CHANGES.md" 2>/dev/null; then
  ok "CHANGES.md has a ## $TARGET section"
else
  bad "$EXT_DIR/CHANGES.md has no '## $TARGET' section; the release notes ship in the archive"
fi

if deno task check >/dev/null 2>&1; then
  ok "deno check passes"
else
  bad "deno check fails (deno task check)"
fi

if docker info >/dev/null 2>&1; then
  ok "docker daemon reachable"
else
  bad "docker daemon is not reachable"
fi

TAG_EXISTED=0
if git rev-parse -q --verify "refs/tags/v$TARGET" >/dev/null 2>&1; then
  TAG_EXISTED=1
  if [ "$MODE" = "new" ]; then
    bad "tag v$TARGET already exists, but $TARGET is not the current build"
  else
    ok "tag v$TARGET exists (it will be moved)"
  fi
else
  ok "tag v$TARGET does not exist yet"
fi

[ "$fail_n" -eq 0 ] || die "preflight failed ($fail_n problem(s) above); nothing was changed"

# ==========================================================================
# The confirm gate. Everything above is read-only.
# ==========================================================================
if [ "$CONFIRM" != "1" ]; then
  echo
  cat >&2 <<EOF
Dry run. release.sh would release $NAME $TARGET ($MODE), in order:

  1. regenerate $EXT_DIR/ at $TARGET$([ "$MODE" = new ] && echo ", write the $CURRENT -> $TARGET upgrade script and prune the $CURRENT full install")
  2. regenerate the packages/*/src/migrations-bundle.ts copies (build output,
     untracked; a smoke check that they still generate)
  3. WIPE BOTH LOCAL DATABASES and run the full suite on each:
       pg-ext-retest.sh   docker compose down -v on semantius-ext (the data
                          volume is destroyed) and rebuilds the base image,
                          which compiles pg_oidc_validator from GitHub
       pg-cli-retest.sh   deno task retest --confirm, i.e. dropall on the CLI
                          stack, then migrate + pgTAP
       pg-ext-lifecycle.sh  install, dump/restore, drop, uninstall, refusals
  4. build ghcr.io/semantius/postgres:$TARGET-pg<major> locally - no push, no
     registry login, but it does retag your local :latest when $TARGET is the
     highest version
  5. commit $EXT_DIR/, then regenerate a second time and require no diff - the
     same porcelain guard CI runs, which is what proves the generator is
     deterministic
  6. tag v$TARGET and push $BRANCH and the tag to origin

  Step 6 is the point of no return. Nothing before it leaves this machine.
  Pushing the tag starts .github/workflows/extension-release.yml, which
  publishes the GitHub Release and the GHCR image.
EOF
  if [ "$MODE" = "refresh" ]; then
    cat >&2 <<EOF

  This is a RE-RELEASE of $TARGET:
    - CI runs 'gh release delete v$TARGET' and recreates it, so the existing
      release's download counts and any hand-edited notes are destroyed.
    - The GHCR image for $TARGET is overwritten.
    - Databases that already installed $TARGET are NOT updated. migrate() skips
      by migration name, there is no checksum re-apply, and there is no
      $TARGET -> $TARGET upgrade path. semantius.status().changed_versions is
      the only signal. See RELEASE.md.
EOF
  fi
  cat >&2 <<EOF

  It does NOT publish to PGXN. That is ./scripts/pgxn-release.sh, by hand, after
  the GitHub Release exists - PGXN releases are permanent.

Re-run with --confirm to proceed:
  ./release.sh $TARGET --confirm
EOF
  exit 1
fi

# ==========================================================================
# Phase 2 - generate
# ==========================================================================
echo
echo "== [2/8] Regenerating $EXT_DIR/ at $TARGET =="
if [ "$ALLOW_EDITED" = "1" ]; then
  deno task extension "$TARGET" --allow-edited-migrations
else
  deno task extension "$TARGET"
fi

echo
echo "== [3/8] Regenerating the migrations bundles =="
# Build output, not artefacts: untracked, and the header carries a generation
# timestamp so the result is not reproducible. Run here only to prove they still
# generate against the current migrations.
deno task bundle-sql

# ==========================================================================
# Phase 3 - verify locally
# ==========================================================================
if [ "$SKIP_TESTS" = "1" ]; then
  echo
  echo "== [4/8] Tests SKIPPED (--skip-tests) =="
else
  echo
  echo "== [4/8] Path B: extension install + pgTAP suite =="
  ./pgdocker/pg-ext-retest.sh

  echo
  echo "== [5/8] Path A: migrate install + pgTAP suite =="
  ./pgdocker/pg-cli-retest.sh

  echo
  echo "== [6/8] Extension lifecycle =="
  # pg-ext-lifecycle.sh reports an unrunnable step as ok("skipped: ...") and
  # ok() increments the pass counter, so a missing container turns the
  # extension-vs-migrate equivalence check into a silent pass. Assert the
  # precondition here rather than editing that 37 KB script.
  for c in postgres18-ext postgres18-cli; do
    docker exec "$c" psql -U postgres -d appdb -tAc 'SELECT 1' >/dev/null 2>&1 \
      || die "$c/appdb is not reachable; pg-ext-lifecycle.sh would silently skip
  the extension-vs-migrate equivalence check instead of failing"
  done
  ./pgdocker/pg-ext-lifecycle.sh
fi

if [ "$NO_IMAGE" = "1" ]; then
  echo
  echo "== [7/8] Local image build SKIPPED (--no-image) =="
else
  echo
  echo "== [7/8] Local image build (no push) =="
  ./docker-postgres/build.sh "$TARGET"
fi

echo
echo "== PGXN manifest =="
bash scripts/check-pgxn-meta.sh "$EXT_DIR/META.json"

# ==========================================================================
# Phase 4 - commit, then prove the build is reproducible
# ==========================================================================
echo
echo "== [8/8] Committing the build =="

# Stage the manifest-derived file set, never `git add -A extension`: extension/
# has no gitignore coverage, so -A would silently commit an orphaned upgrade
# script or a stray file, and from there it reaches the published archive.
bash scripts/archive-manifest.sh "$TARGET" --check > /tmp/release-manifest.$$ \
  || { rm -f /tmp/release-manifest.$$; die "the archive file set is not clean (see above); $EXT_DIR/ is regenerated but nothing was committed"; }
while read -r src _name; do
  case "$src" in "$EXT_DIR"/*) git add -- "$src" ;; esac
done < /tmp/release-manifest.$$
rm -f /tmp/release-manifest.$$
# Deletions inside extension/ (a pruned full install) are staged explicitly.
git add -u -- "$EXT_DIR"

NOTHING_CHANGED=0
if git diff --cached --quiet; then
  NOTHING_CHANGED=1
  echo "  nothing to commit - $EXT_DIR/ already matches the generated build"
else
  if [ "$MODE" = "new" ]; then
    SUBJECT="Release v$TARGET: regenerate the extension build"
  else
    SUBJECT="Re-release v$TARGET: refresh the extension build"
  fi
  {
    echo "$SUBJECT"
    echo
    echo "Generated by ./release.sh $TARGET. Full install $NAME--$TARGET.sql;"
    echo "default_version $TARGET."
    [ "$ALLOW_EDITED" = "1" ] && { echo; echo "Allow-edited-migrations: yes"; }
  } | git commit -q -F -
  echo "  committed $(git rev-parse --short HEAD)"
fi
RELEASE_COMMIT="$(git rev-parse HEAD)"

if [ "$MODE" = "new" ] && [ "$NOTHING_CHANGED" = "1" ]; then
  die "internal: generating a new version produced no changes; expected at least
  a new full install, an upgrade script and a bumped default_version"
fi

# The CI porcelain guard, run locally. It must come AFTER the commit: before it,
# the diff is the new build itself and the check would be vacuous. What it
# actually proves is that the generator is deterministic - which is the only
# reason the CI guard can work, and which any future generated field carrying a
# build timestamp would silently break.
echo "  verifying the build is reproducible..."
if [ "$ALLOW_EDITED" = "1" ]; then
  deno task extension "$TARGET" --allow-edited-migrations >/dev/null
else
  deno task extension "$TARGET" >/dev/null
fi
if [ -n "$(git status --porcelain -- "$EXT_DIR")" ]; then
  git status --porcelain -- "$EXT_DIR" >&2
  die "regenerating $TARGET a second time produced a different $EXT_DIR/.
  CI's porcelain guard would fail on this tag, so nothing was tagged.
  The build IS committed as $(git rev-parse --short HEAD).
  Recover with:  git checkout -- $EXT_DIR && git reset --hard HEAD~1"
fi
echo "  reproducible"

# ==========================================================================
# Phase 5 - tag and push
# ==========================================================================
tag_and_push() {
  # Preconditions restated here so a future reordering fails loudly instead of
  # publishing a tag whose extension/ was never committed.
  [ -n "${RELEASE_COMMIT:-}" ] || die "internal: tag_and_push before commit"
  [ "$(git rev-parse HEAD)" = "$RELEASE_COMMIT" ] \
    || die "HEAD moved after the release commit; refusing to tag"
  [ -z "$(git status --porcelain -- "$EXT_DIR")" ] \
    || die "$EXT_DIR/ is not committed; CI's porcelain guard would fail. Refusing to tag."

  # The fast-forward check in phase 1 is tens of minutes stale by now.
  git fetch --quiet origin "$BRANCH" 2>/dev/null || true
  if [ -n "$UPSTREAM" ] && [ "$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)" != "0" ]; then
    die "$UPSTREAM moved while the tests ran; the push would be rejected.
  The build is committed. Pull, re-run the harnesses, and re-run release.sh."
  fi

  if [ "$TAG_EXISTED" = "1" ]; then
    git tag -f "v$TARGET" >/dev/null
  else
    git tag "v$TARGET"
  fi
  echo "  tagged v$TARGET"

  # Branch first: a tag on a commit that is not on the branch still triggers the
  # workflow, which would then publish a release for an unreachable commit.
  if ! git push origin "$BRANCH"; then
    [ "$TAG_EXISTED" = "1" ] || git tag -d "v$TARGET" >/dev/null
    die "pushing $BRANCH was rejected; the local tag was removed so the next run
  does not force-push it. Pull, re-run the harnesses, and re-run release.sh."
  fi

  if [ "$TAG_EXISTED" = "1" ]; then
    git push --force origin "v$TARGET"
  else
    git push origin "v$TARGET"
  fi
  echo "  pushed v$TARGET"
}

echo
if [ "$SKIP_TESTS" = "1" ]; then
  cat >&2 <<EOF
--skip-tests was used, so nothing was proven locally.

  v$TARGET was NOT created and nothing was pushed. The regenerated build is
  committed as $(git rev-parse --short HEAD) and can be amended or reset:
    git reset --hard HEAD~1

  The split of responsibility is that the harnesses run HERE to prove the
  current state is green, and CI re-runs them to prove it is reproducible.
  Tagging without the local run makes CI the only check, which is exactly what
  the split exists to prevent.

  Re-run without --skip-tests to tag and push:
    ./release.sh $TARGET --confirm
EOF
  exit 1
fi

EXISTING_TAG_COMMIT=""
[ "$TAG_EXISTED" = "1" ] && EXISTING_TAG_COMMIT="$(git rev-parse "v$TARGET^{commit}")"

if [ "$NOTHING_CHANGED" = "1" ] && [ "$EXISTING_TAG_COMMIT" = "$(git rev-parse HEAD)" ]; then
  if [ "$RERUN_CI" = "1" ]; then
    # Delete and re-push the remote tag rather than dispatching the workflow:
    # this produces a genuine push event and therefore runs the same code path a
    # real release does. A workflow_dispatch takes the other branch of "Resolve
    # version" and its bare actions/checkout would check out the default branch.
    echo "== Re-running CI for the existing v$TARGET =="
    git push origin ":refs/tags/v$TARGET"
    git push origin "v$TARGET"
    echo "  re-pushed v$TARGET; the workflow will run again"
  else
    cat >&2 <<EOF
release.sh: v$TARGET already points at HEAD ($(git rev-parse --short HEAD)) and
regenerating $TARGET changed nothing.

  Force-pushing a tag to the commit it already points at sends no ref update, so
  no push event is emitted, the release workflow does NOT run, and nothing would
  be republished. This run would be silently pointless.

  Pick one:
    - Nothing to do: the published v$TARGET already is this build.
    - Re-run the workflow against the same commit:
        ./release.sh $TARGET --confirm --rerun-ci
    - Change something first, then re-run release.sh.
EOF
    exit 1
  fi
else
  tag_and_push
fi

# ==========================================================================
# Hand over to CI
# ==========================================================================
REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || true)"
cat <<EOF

Done locally. CI now rebuilds from a clean checkout and publishes.

  Watch it:      gh run watch --repo ${REPO:-<owner/repo>} \$(gh run list --repo ${REPO:-<owner/repo>} --workflow extension-release.yml --limit 1 --json databaseId -q '.[0].databaseId')
  Or open:       https://github.com/${REPO:-<owner/repo>}/actions/workflows/extension-release.yml
  When green:    gh release view v$TARGET --repo ${REPO:-<owner/repo>}

  The step to watch for is "Committed build must equal the regenerated one" -
  that is the reproducibility proof this whole split exists for.

  PGXN is NOT part of this and is permanent once done:
    ./scripts/pgxn-release.sh $TARGET --confirm
EOF
