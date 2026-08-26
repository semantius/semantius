#!/usr/bin/env bash
# Build + run the EXTENSION variant: PostgreSQL with Semantius core installed as
# an extension (CREATE EXTENSION pg_semantius), instead of the CLI migrate path.
# For the plain CLI-testing container, use pg-cli-create.sh.
#
# Runs as its own compose project (semantius-ext) on port 5433, so it sits next
# to the CLI-testing container without colliding.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit POSTGRES_PASSWORD if you want."
fi

# The extension must be generated first (repo root -> ../extension).
if ! ls ../extension/pg_semantius--*.sql >/dev/null 2>&1; then
  echo "No extension build found in ../extension." >&2
  echo "Generate it first, from the repo root:  deno task extension" >&2
  exit 1
fi

# 1) Build the base OAuth image that Dockerfile.ext layers on top of.
docker compose build postgres
# 2) Build + start the extension variant as its own isolated project.
docker compose -f docker-compose.ext.yml -p semantius-ext up -d --build
docker compose -f docker-compose.ext.yml -p semantius-ext ps
echo
echo "Ready (extension variant). DBA connection string:"
echo "  postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5433/appdb"
