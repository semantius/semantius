#!/usr/bin/env bash
# Show the EXTENSION container's status: created / running (healthy) / exited.
# Prints nothing under the header if it has been deleted (pg-ext-stop).
cd "$(dirname "$0")" || exit 1
docker compose -f docker-compose.ext.yml -p semantius-ext ps -a
