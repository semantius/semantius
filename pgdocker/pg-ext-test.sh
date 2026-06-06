#!/usr/bin/env bash
# Run the OAuth checks against the running EXTENSION container (needs Deno on
# PATH). The extension installs _core, so rbac.uid() exists and the security
# check has its baseline. Targets the extension stack's port (default 5433):
#   verify_oauth.ts        - server validates the token + publishes the claims
#   test_oauth_security.ts - a hostile client cannot impersonate
cd "$(dirname "$0")" || exit 1

PORT="${POSTGRES_EXT_PORT:-5433}"

echo "== verify_oauth.ts (port $PORT) =="
deno run --allow-net verify_oauth.ts --port "$PORT"
v=$?

echo
echo "== test_oauth_security.ts (port $PORT) =="
deno run --allow-net test_oauth_security.ts --port "$PORT"
t=$?

echo
echo "verify=$v  security=$t   (0 = ok; security 2 = extension/_core not installed)"
[ "$v" -eq 0 ] && exit "$t" || exit "$v"
