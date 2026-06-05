#!/usr/bin/env bash
# Stop and remove the container + network. The data volume is KEPT, so a later
<<<<<<< HEAD
# ./pg-start.sh resumes with the same database.
=======
# ./start.sh resumes with the same database.
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
set -euo pipefail
cd "$(dirname "$0")"

docker compose down
<<<<<<< HEAD
echo "Stopped. Data volume kept — ./pg-start.sh to resume."
=======
echo "Stopped. Data volume kept — ./start.sh to resume."
>>>>>>> fe81bf7ce46305effe75b62721279acf0977134e
