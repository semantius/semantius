#!/usr/bin/env bash
# Destroy the PostgREST stack: its containers, network, and data + jwks volumes.
# Keeps the semantius-db image (a reusable, versioned artifact — rebuild/pull as
# needed) and leaves the pgdocker stacks untouched.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the pgrest DB volume (all data). Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

docker compose down -v
echo "Removed the pgrest containers, network, and data + jwks volumes (image kept)."
