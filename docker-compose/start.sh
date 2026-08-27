#!/usr/bin/env bash
# Start the PostgREST-stack containers that create.sh / up.sh already created.
# This ONLY starts existing (stopped) containers — it never creates them. If the
# containers are gone, run ./up.sh (keeps the database) or ./create.sh (fresh one).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./create.sh first (it copies .env.example)." >&2
  exit 1
fi

if [ -z "$(docker compose ps -aq)" ]; then
  echo "No containers exist. Run ./up.sh (keeps any existing data) or ./create.sh (fresh database)." >&2
  exit 1
fi

docker compose start
docker compose ps
