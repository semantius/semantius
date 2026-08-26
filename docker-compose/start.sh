#!/usr/bin/env bash
# Start the PostgREST-stack containers that pg-rest-create.sh already created.
# This ONLY starts existing (stopped) containers — it never creates them. If the
# stack has not been created yet (or was destroyed), run ./pg-rest-create.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./pg-rest-create.sh first (it copies .env.example)." >&2
  exit 1
fi

if [ -z "$(docker compose ps -aq)" ]; then
  echo "No containers exist. Run ./pg-rest-create.sh first." >&2
  exit 1
fi

docker compose start
docker compose ps
