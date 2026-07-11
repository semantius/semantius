#!/usr/bin/env bash
# Start the PostgREST-stack containers (reuses the existing image; recreates
# containers if needed). Use pg-rest-create.sh instead if you regenerated the
# extension (deno task extension) or changed the Dockerfile.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./pg-rest-create.sh first (it copies .env.example)." >&2
  exit 1
fi

docker compose up -d
docker compose ps
