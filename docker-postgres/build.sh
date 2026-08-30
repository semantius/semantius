#!/usr/bin/env bash
# Build the self-contained Semantius DB image (PostgreSQL 18 + pg_semantius
# installed, pg_hba + roles + authenticator LOGIN + optional nwind module baked in)
# locally, from the extension files currently in ./extension.
#
#   ./build.sh              # version inferred from ./extension
#   ./build.sh 0.3.0        # explicit version tag
#
# Builds + tags (one image, three names):
#     ghcr.io/semantius/postgres:<version>-pg<major>   canonical, immutable
#     ghcr.io/semantius/postgres:latest-pg<major>      moving, major pinned
#     ghcr.io/semantius/postgres:latest                moving, default major
# There is deliberately NO bare :<version> tag — a version tag that silently
# changed Postgres major later is exactly the ambiguity the suffix removes.
#
# This does NOT regenerate the extension — it packages whatever is in ./extension.
# If you changed migrations, regenerate first with an EXPLICIT version (bare
# `deno task extension` falls back to the CLI's own 0.1.0 and downgrades the build):
#     deno task extension 0.3.0
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

echo "Building ${IMAGE}:${version}-pg${pg_major} (+ :latest-pg${pg_major}, :latest) ..."
docker build \
  -f docker-postgres/Dockerfile \
  -t "${IMAGE}:${version}-pg${pg_major}" \
  -t "${IMAGE}:latest-pg${pg_major}" \
  -t "${IMAGE}:latest" \
  .

echo
echo "Built:"
echo "  ${IMAGE}:${version}-pg${pg_major}"
echo "  ${IMAGE}:latest-pg${pg_major}"
echo "  ${IMAGE}:latest"
echo "Publish with:  IMAGE=${IMAGE} docker-postgres/publish.sh ${version}"
