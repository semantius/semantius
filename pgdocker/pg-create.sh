#!/usr/bin/env bash
# Build the image and create + start the container (first run, or after changing
# the Dockerfile / patches). Creates .env from the template if missing.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit POSTGRES_PASSWORD if you want."
fi

docker compose up -d --build
docker compose ps
echo
echo "Ready. DBA connection string:"
echo "  postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5432/appdb"
