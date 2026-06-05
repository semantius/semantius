#!/usr/bin/env bash
# Start the container (reuses the existing image; recreates the container if
<<<<<<< HEAD
# needed). Use pg-create.sh instead if you changed the Dockerfile or patches.
=======
# needed). Use create.sh instead if you changed the Dockerfile or patches.
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
<<<<<<< HEAD
  echo "No .env found. Run ./pg-create.sh first (it copies .env.example)." >&2
=======
  echo "No .env found. Run ./create.sh first (it copies .env.example)." >&2
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
  exit 1
fi

docker compose up -d
docker compose ps
