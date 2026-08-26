#!/usr/bin/env bash
# Stop the PostgREST-stack containers WITHOUT removing them. Containers, network,
# and volumes are all KEPT, so ./start.sh resumes the same containers.
# Use ./destroy.sh to actually remove containers + data.
set -euo pipefail
cd "$(dirname "$0")"

docker compose stop
echo "Stopped. Containers kept — ./start.sh to resume."
