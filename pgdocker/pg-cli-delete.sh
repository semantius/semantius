#!/usr/bin/env bash
# Destroy everything: container, network, the DATA VOLUME (database is erased),
# and the locally built image. Asks for confirmation first.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the database volume and the built image. Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Canceled."; exit 0 ;;
esac

docker compose down -v --rmi local
echo "Removed container, network, data volume, and image."
