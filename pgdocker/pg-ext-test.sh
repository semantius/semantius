#!/usr/bin/env bash
# Run all auth checks against the running EXTENSION container (needs Deno on
# PATH). The extension installs _core, so rbac.uid()/get_userinfo() exist and the
# _core-dependent checks have their baseline. Targets the ext stack port (5433):
#   verify_oauth.ts        - bearer: server validates the token + publishes claims
#   test_oauth_security.ts - bearer: a hostile client cannot impersonate
#   verify_session.ts      - session: SCRAM connect + SET ROLE + claims -> RLS
#   test_session_trust.ts  - session: trust model + NOINHERIT/no-claims/bad-role negatives
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
echo "== verify_session.ts (port $PORT) =="
deno run --allow-net --allow-env --allow-read verify_session.ts --port "$PORT"
vs=$?

echo
echo "== test_session_trust.ts (port $PORT) =="
deno run --allow-net --allow-env --allow-read test_session_trust.ts --port "$PORT"
ts=$?

echo
echo "verify=$v  security=$t  verify_session=$vs  session_trust=$ts   (0 = ok; 2 = extension/_core not installed)"

# Aggregate: the bearer happy path must be 0; the _core-dependent checks may be 0
# (ok) or 2 (skipped). Anything else is a real failure.
rc=0
[ "$v" -eq 0 ] || rc=1
for code in "$t" "$vs" "$ts"; do
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ] || rc=1
done
exit "$rc"
