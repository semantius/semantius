#!/usr/bin/env bash
# Show the container's status: created / running (healthy) / exited.
# Prints nothing under the header if it has been deleted (docker compose down).
cd "$(dirname "$0")" || exit 1
docker compose ps -a
