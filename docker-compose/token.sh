#!/usr/bin/env bash
# Mint a JWT for a test user from the OIDC issuer and print it to stdout, so you
# can paste it into the Scalar docs "Authentication" box or use it with curl.
#
#   ./token.sh                 # default user: user1
#   ./token.sh user2           # a specific user
#   TOKEN=$(./token.sh user3)  # capture just the token
#
# Test-issuer users: user1 (John Smith), user2 (María García), user3 (Wei Chen).
# Reuses ../pgdocker/get_user_token.ts (mints from the OIDC test issuer, which is
# hardcoded in pgdocker/verify_oauth.ts). The token is printed on
# stdout; the usage hint goes to stderr, so `$(...)` capture stays clean.
set -euo pipefail
cd "$(dirname "$0")"

# Port hints come from the stack's .env — it lives in the semantius-self-hosted
# repo (default: a sibling checkout; override with SELF_HOSTED_DIR). Optional:
# the defaults below are right for a stock stack.
SELF_HOSTED_DIR="${SELF_HOSTED_DIR:-$(cd .. && pwd)/../semantius-self-hosted}"
[ -f "$SELF_HOSTED_DIR/.env" ] && { set -a; . "$SELF_HOSTED_DIR/.env"; set +a; }

[ "$#" -gt 0 ] || set -- user1
token="$(deno run --allow-net --allow-read ../pgdocker/get_user_token.ts "$@" 2>/dev/null)"
[ -n "$token" ] || { echo "failed to mint a token (is deno installed? issuer reachable?)" >&2; exit 1; }

printf '%s\n' "$token"          # stdout = just the token

{
  base="http://localhost:${POSTGREST_PORT:-3100}"
  echo
  echo "Use it:"
  echo "  • Scalar docs (http://localhost:${DOCS_PORT:-8080}) → Authentication → JWT →"
  echo "    paste the whole header value:  Bearer <the token above>"
  echo
  echo "  • curl:  curl -H \"Authorization: Bearer \$(./token.sh ${1:-user1})\" \\"
  echo "             ${base}/users"
  echo
  echo "  • Copy-paste curl (whoami via /rpc/get_userinfo):"
  echo "    (POST, not GET — get_userinfo() upserts the user, so it needs a"
  echo "     read-write transaction; a GET fails with 25006 read-only-transaction.)"
  echo
  echo "    curl -s -X POST ${base}/rpc/get_userinfo \\"
  echo "      -H 'Authorization: Bearer ${token}' \\"
  echo "      -H 'Content-Type: application/json' -d '{}'"
} >&2
