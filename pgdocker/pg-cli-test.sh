#!/usr/bin/env bash
# Run all auth checks against the running CLI container (needs Deno on PATH):
#   verify_oauth.ts        - bearer: server validates the token + publishes claims
#   test_oauth_security.ts - bearer: a hostile client cannot impersonate (needs _core)
#   verify_session.ts      - session: SCRAM connect + SET ROLE + claims -> RLS (needs _core)
#   test_session_trust.ts  - session: trust model + NOINHERIT/no-claims/bad-role negatives
cd "$(dirname "$0")" || exit 1

echo "== verify_oauth.ts =="
deno run --allow-net verify_oauth.ts
v=$?

echo
echo "== test_oauth_security.ts =="
deno run --allow-net test_oauth_security.ts
t=$?

echo
echo "== verify_session.ts =="
deno run --allow-net --allow-env --allow-read verify_session.ts
vs=$?

echo
echo "== test_session_trust.ts =="
deno run --allow-net --allow-env --allow-read test_session_trust.ts
ts=$?

echo
echo "verify=$v  security=$t  verify_session=$vs  session_trust=$ts   (0 = ok; 2 = _core not deployed)"

# Aggregate: the bearer happy path must be 0; the _core-dependent checks may be 0
# (ok) or 2 (skipped — _core not deployed). Anything else is a real failure.
rc=0
[ "$v" -eq 0 ] || rc=1
for code in "$t" "$vs" "$ts"; do
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ] || rc=1
done
exit "$rc"
