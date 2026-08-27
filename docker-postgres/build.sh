#!/usr/bin/env bash
# Build the self-contained Semantius DB image (PostgreSQL 18 + pg_semantius
# installed, pg_hba + roles + authenticator LOGIN + optional nwind module baked in)
# locally, from the extension files currently in ./extension.
#
#   ./build.sh              # version inferred from ./extension
#   ./build.sh 0.3.0        # explicit version tag
#
# Builds + tags:
#     ghcr.io/semantius/semantius-db:<version>
#     ghcr.io/semantius/semantius-db:latest
#
# This does NOT regenerate the extension — it packages whatever is in ./extension.
# If you changed migrations, regenerate first with an EXPLICIT version (bare
# `deno task extension` falls back to the CLI's own 0.1.0 and downgrades the build):
#     deno task extension 0.3.0
#
# The :latest tag means a local `docker compose up` (e.g. in ../docker-compose)
# uses THIS freshly-built image without pulling. Push it with ./publish.sh.
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root (build context; COPYs ./extension)

IMAGE="${IMAGE:-ghcr.io/semantius/semantius-db}"

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

echo "Building ${IMAGE}:${version} (+ :latest) ..."
docker build \
  -f docker-semantius/Dockerfile \
  -t "${IMAGE}:${version}" \
  -t "${IMAGE}:latest" \
  .

echo
echo "Built:"
echo "  ${IMAGE}:${version}"
echo "  ${IMAGE}:latest"
echo "Publish with:  IMAGE=${IMAGE} docker-semantius/publish.sh ${version}"
