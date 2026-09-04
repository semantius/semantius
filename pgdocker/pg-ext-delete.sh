#!/usr/bin/env bash
# Destroy the EXTENSION variant only: its container, network, data volume, and
# the postgres18-ext:local image. Leaves the CLI-testing stack untouched.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the extension DB volume and image. Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Canceled."; exit 0 ;;
esac

docker compose -f docker-compose.ext.yml -p semantius-ext down -v --rmi local
echo "Removed the extension container, network, data volume, and image."
