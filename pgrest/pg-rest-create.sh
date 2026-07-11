#!/usr/bin/env bash
# Build + run the PostgREST stack: PostgreSQL 18 + the pg_semantic_platform
# extension, fronted by PostgREST (HTTP + OpenAPI) and a Scalar docs site. Runs as
# its own compose project (semantius-rest, set by `name:` in docker-compose.yml) on
# port 5434, alongside the pgdocker CLI (5432) and ext (5433) stacks.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit passwords/ports if you want."
fi

# The extension must be generated first (repo root -> ../extension).
if ! ls ../extension/pg_semantic_platform--*.sql >/dev/null 2>&1; then
  echo "No extension build found in ../extension." >&2
  echo "Generate it first, from the repo root:  deno task extension" >&2
  exit 1
fi

docker compose up -d --build
docker compose ps

set -a; . ./.env; set +a
echo
echo "Ready (PostgREST stack)."
echo "  API   : http://localhost:${POSTGREST_PORT:-3000}/   (OpenAPI spec at /)"
echo "  Docs  : http://localhost:${DOCS_PORT:-8080}/         (Scalar API reference)"
echo "  DBA   : postgresql://postgres:<POSTGRES_PASSWORD>@localhost:${POSTGRES_PORT:-5434}/appdb"
