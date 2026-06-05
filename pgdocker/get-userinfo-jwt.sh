#!/usr/bin/env bash
# Show public.get_userinfo() for a given JWT (presented to Postgres via OAuth).
# Prints the user-info JSON, the error, or a usage notice if no JWT is passed.
#   ./get-userinfo-jwt.sh <jwt>
cd "$(dirname "$0")" || exit 1
deno run --allow-net get_userinfo_jwt.ts "$@"
