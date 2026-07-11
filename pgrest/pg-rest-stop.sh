#!/usr/bin/env bash
# Stop and remove the PostgREST-stack containers + network. The data + jwks
# volumes are KEPT, so a later ./pg-rest-start.sh resumes with the same database.
set -euo pipefail
cd "$(dirname "$0")"

docker compose down
echo "Stopped. Data volume kept — ./pg-rest-start.sh to resume."
