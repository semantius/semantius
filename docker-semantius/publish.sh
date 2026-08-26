#!/usr/bin/env bash
# Push the Semantius DB image to the GitHub Container Registry (GHCR).
#
#   ./publish.sh            # version from extension/META.json
#   ./publish.sh 0.2.0      # explicit version
#
# Pushes both :<version> and :latest. Assumes ./build.sh already built those tags
# locally. Requires a GHCR login first:
#     echo "$GITHUB_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
# (token needs write:packages). CI does this automatically — see
# .github/workflows/extension-release.yml; this script is for manual pushes.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root (to read extension/META.json)

IMAGE="${IMAGE:-ghcr.io/semantius/semantius-db}"

# Version: arg wins, else the version of the currently-built extension.
version="${1:-$(ls extension/pg_semantic_platform--*.sql 2>/dev/null \
  | sed -E 's/.*--([0-9.]+)\.sql/\1/' | sort -V | tail -1)}"
[ -n "$version" ] || { echo "could not resolve version — pass it explicitly: publish.sh <version>" >&2; exit 1; }

echo "Pushing ${IMAGE}:${version} and ${IMAGE}:latest ..."
docker push "${IMAGE}:${version}"
docker push "${IMAGE}:latest"
echo "Done."
