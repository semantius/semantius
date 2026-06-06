#!/usr/bin/env bash
# Stop and remove the container + network. The data volume is KEPT, so a later
# ./pg-start.sh resumes with the same database.
set -euo pipefail
cd "$(dirname "$0")"

docker compose down
echo "Stopped. Data volume kept — ./pg-start.sh to resume."
