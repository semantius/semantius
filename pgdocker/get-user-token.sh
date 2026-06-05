#!/usr/bin/env bash
# Print a JWT access token for a user, minted from the test OIDC server.
# Prints the token, or an error if the name is missing / no token is returned.
#   ./get-user-token.sh <user-name>
cd "$(dirname "$0")" || exit 1
deno run --allow-net --allow-read get_user_token.ts "$@"
