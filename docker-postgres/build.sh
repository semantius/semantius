#!/usr/bin/env bash
# Build the self-contained Semantius DB image (PostgreSQL 18 + pg_semantius
# installed, pg_hba + roles + authenticator LOGIN + optional nwind module baked in)
# locally, from the extension files currently in ./extension.
#
#   ./build.sh              # version inferred from ./extension
#   ./build.sh 0.3.0        # explicit version tag
#
# Builds + tags (one image, three names):
#     ghcr.io/semantius/postgres:<version>-pg<major>   canonical; moves while
#                                                      that version is newest
#     ghcr.io/semantius/postgres:latest-pg<major>      moving, major pinned
#     ghcr.io/semantius/postgres:latest                moving, default major
#
# The two :latest* tags are only applied when <version> is the highest v* tag in
# the repo, so building an older version cannot shadow a newer local image.
# There is deliberately NO bare :<version> tag — a version tag that silently
# changed Postgres major later is exactly the ambiguity the suffix removes.
#
# This does NOT regenerate the extension — it packages whatever is in ./extension.
# If you changed migrations, regenerate first; the version is required:
#     deno task extension 0.5.0
# See RELEASE.md for when a version may be regenerated and when it is frozen.
#
# The :latest tag means a consumer stack can run THIS freshly-built image — but
# only if it does not pull over it, so use the semantius-self-hosted stack's
# `./up.sh --no-pull` / `./create.sh -y --no-pull`. Push it with ./publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root (build context; COPYs ./extension)

IMAGE="${IMAGE:-ghcr.io/semantius/postgres}"

# Postgres major for the tag suffix. Parsed from the Dockerfile's FROM line so
# it is a single source of truth and the tag can never claim a major the image
# does not actually have.
pg_major="$(sed -nE 's|^FROM postgres:([0-9]+).*|\1|p' docker-postgres/Dockerfile | head -1)"
[ -n "$pg_major" ] || { echo "could not parse the Postgres major from docker-postgres/Dockerfile" >&2; exit 1; }

# The build COPYs ./extension — fail early if it hasn't been generated.
if ! ls extension/pg_semantius--*.sql >/dev/null 2>&1; then
  echo "No extension build in ./extension. Generate it first:  deno task extension <version>" >&2
  exit 1
fi

# The build also COPYs + merges the Northwind demo migrations into the image.
for f in apps/nwind/migrations/0010_create.sql apps/nwind/migrations/0020_load_data.sql; do
  [ -f "$f" ] || { echo "Missing $f (needed to bake the optional nwind module)." >&2; exit 1; }
done

# Version: arg wins, else infer from the built extension SQL filename.
version="${1:-$(ls extension/pg_semantius--*.sql 2>/dev/null \
  | sed -E 's/.*--([0-9.]+)\.sql/\1/' | sort -V | tail -1)}"
[ -n "$version" ] || { echo "could not resolve version — pass it explicitly: build.sh <version>" >&2; exit 1; }


# The moving :latest* tags may only follow the HIGHEST released version. Without
# this, re-releasing an older version drags :latest backwards - silently, and for
# everyone who pulls it. The version-pinned tag is always produced: that is what
# makes a re-release replace its own image. Mirrors the same decision in
# .github/workflows/extension-release.yml.
git fetch --tags --force --quiet 2>/dev/null || true
top_version="$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1)"
# ">= the highest tag", not "== it": during a local release the tag for the
# version being built does not exist yet, and a fresh clone may have no tags.
if [ -z "$top_version" ] ||    [ "$(printf '%s
%s
' "$top_version" "$version" | sort -V | tail -1)" = "$version" ]; then
  is_highest=1
else
  is_highest=0
fi

if [ "$is_highest" = "1" ]; then
  echo "Building ${IMAGE}:${version}-pg${pg_major} (+ :latest-pg${pg_major}, :latest) ..."
  docker build \
    -f docker-postgres/Dockerfile \
    -t "${IMAGE}:${version}-pg${pg_major}" \
    -t "${IMAGE}:latest-pg${pg_major}" \
    -t "${IMAGE}:latest" \
    .
else
  echo "Building ${IMAGE}:${version}-pg${pg_major} only (${top_version} is newer; :latest stays where it is) ..."
  docker build \
    -f docker-postgres/Dockerfile \
    -t "${IMAGE}:${version}-pg${pg_major}" \
    .
fi

echo
echo "Built:"
echo "  ${IMAGE}:${version}-pg${pg_major}"
if [ "$is_highest" = "1" ]; then
  echo "  ${IMAGE}:latest-pg${pg_major}"
  echo "  ${IMAGE}:latest"
fi
echo "Publish with:  IMAGE=${IMAGE} docker-postgres/publish.sh ${version}"
