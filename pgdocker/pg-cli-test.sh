#!/usr/bin/env bash
# Run the OAuth checks against the running container (needs Deno on PATH):
#   verify_oauth.ts        - server validates the token + publishes the claims
#   test_oauth_security.ts - a hostile client cannot impersonate (needs _core deployed)
cd "$(dirname "$0")" || exit 1

echo "== verify_oauth.ts =="
deno run --allow-net verify_oauth.ts
v=$?

echo
echo "== test_oauth_security.ts =="
deno run --allow-net test_oauth_security.ts
t=$?

echo
echo "verify=$v  security=$t   (0 = ok; security 2 = _core not deployed)"
[ "$v" -eq 0 ] && exit "$t" || exit "$v"
