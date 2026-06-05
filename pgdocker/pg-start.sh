#!/usr/bin/env bash
# Start the container (reuses the existing image; recreates the container if
# needed). Use pg-create.sh instead if you changed the Dockerfile or patches.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./pg-create.sh first (it copies .env.example)." >&2
  exit 1
fi

docker compose up -d
docker compose ps
