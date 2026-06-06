#!/usr/bin/env bash
# Start the EXTENSION-variant container (reuses the existing image; recreates the
# container if needed). Use pg-ext-create.sh instead if you regenerated the
# extension (deno task extension) or changed the Dockerfile.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./pg-ext-create.sh first (it copies .env.example)." >&2
  exit 1
fi

docker compose -f docker-compose.ext.yml -p semantius-ext up -d
docker compose -f docker-compose.ext.yml -p semantius-ext ps
