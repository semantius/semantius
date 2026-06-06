#!/usr/bin/env bash
# Stop and remove the EXTENSION container + network. The data volume is KEPT, so
# a later ./pg-ext-start.sh resumes with the same database.
set -euo pipefail
cd "$(dirname "$0")"

docker compose -f docker-compose.ext.yml -p semantius-ext down
echo "Stopped. Data volume kept — ./pg-ext-start.sh to resume."
