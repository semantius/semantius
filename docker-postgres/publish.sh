#!/usr/bin/env bash
# Push the Semantius DB image to the GitHub Container Registry (GHCR).
#
#   ./publish.sh            # version inferred from the built extension SQL
#   ./publish.sh 0.3.0      # explicit version
#
# Pushes :<version>-pg<major>, :latest-pg<major> and :latest. Assumes ./build.sh
# already built those tags locally. Requires a GHCR login first:
#     echo "$GITHUB_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
# (token needs write:packages). CI does this automatically — see
# .github/workflows/extension-release.yml; this script is for manual pushes.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root (to read extension/META.json)

# Semver ordering, not `sort -V` (which ranks 0.6.0 BELOW 0.6.0-beta).
. scripts/semver.sh

IMAGE="${IMAGE:-ghcr.io/semantius/postgres}"

# Postgres major for the tag suffix — parsed from the Dockerfile, same as build.sh.
pg_major="$(sed -nE 's|^FROM postgres:([0-9]+).*|\1|p' docker-postgres/Dockerfile | head -1)"
[ -n "$pg_major" ] || { echo "could not parse the Postgres major from docker-postgres/Dockerfile" >&2; exit 1; }

# Version: arg wins, else the control file's default_version - the one
# authoritative value, and unlike a filename glob it can neither pick an upgrade
# script nor mis-parse a pre-release suffix.
version="${1:-$(sed -nE "s/^default_version = '(.*)'/\1/p" extension/pg_semantius.control 2>/dev/null)}"
version="${version#v}"
[ -n "$version" ] || { echo "could not resolve version — pass it explicitly: publish.sh <version>" >&2; exit 1; }


# The moving :latest* tags may only follow the HIGHEST released version. Without
# this, re-releasing an older version drags :latest backwards - silently, and for
# everyone who pulls it. The version-pinned tag is always produced: that is what
# makes a re-release replace its own image. Mirrors the same decision in
# .github/workflows/extension-release.yml.
git fetch --tags --force --quiet 2>/dev/null || true
top_version="$(git tag -l 'v*' | semver_max_of)"
# ">= the highest tag", not "== it": during a local release the tag for the
# version being built does not exist yet, and a fresh clone may have no tags.
if [ -z "$top_version" ] || [ "$(semver_cmp "$version" "$top_version")" != "-1" ]; then
  is_highest=1
else
  is_highest=0
fi

docker push "${IMAGE}:${version}-pg${pg_major}"
if [ "$is_highest" = "1" ]; then
  docker push "${IMAGE}:latest-pg${pg_major}"
  docker push "${IMAGE}:latest"
  echo "Done: pushed ${version}-pg${pg_major}, :latest-pg${pg_major} and :latest."
else
  echo "Done: pushed ${version}-pg${pg_major} only - ${top_version} is newer, so :latest was left alone." >&2
fi
