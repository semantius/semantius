#!/usr/bin/env bash
# Destroy the PostgREST stack: its containers, network, and data + jwks volumes.
# Keeps the semantius/postgres image (a reusable, versioned artifact — rebuild/pull as
# needed) and leaves the pgdocker stacks untouched.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the PostgREST stack's DB volume (all data). Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

docker compose down -v
echo "Removed the PostgREST stack's containers, network, and data + jwks volumes (image kept)."
