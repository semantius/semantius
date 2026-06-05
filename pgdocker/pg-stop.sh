#!/usr/bin/env bash
# Stop and remove the container + network. The data volume is KEPT, so a later
# ./start.sh resumes with the same database.
set -euo pipefail
cd "$(dirname "$0")"

docker compose down
echo "Stopped. Data volume kept — ./start.sh to resume."
