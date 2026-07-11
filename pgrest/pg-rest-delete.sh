#!/usr/bin/env bash
# Destroy the PostgREST stack: its containers, network, data + jwks volumes, and
# the postgres18-rest:local image. Leaves the pgdocker stacks untouched.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the pgrest DB volume and image. Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

docker compose down -v --rmi local
echo "Removed the pgrest containers, network, data + jwks volumes, and image."
