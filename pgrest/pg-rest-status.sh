#!/usr/bin/env bash
# Show the PostgREST-stack containers' status: created / running (healthy) / exited.
# Prints only the header once the stack has been deleted (pg-rest-delete).
cd "$(dirname "$0")" || exit 1
docker compose ps -a
