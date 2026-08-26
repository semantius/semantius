#!/usr/bin/env bash
# Smoke-test the running PostgREST stack (needs curl; steps 2-4 need Deno).
# The core flow: mint a JWT from the test issuer, then read real data with it.
#   1. GET the OpenAPI spec at / WITHOUT a token  -> proves anon spec visibility.
#   2. Mint a token for a test user from the issuer (reuses ../pgdocker/get_user_token.ts).
#   3. POST an RPC WITH the token   -> JWKS verify + SET ROLE authenticated + rbac.uid(); shows identity.
#   4. GET a table WITH the token   -> real rows via RLS.
#   5. GET a table WITHOUT a token  -> anon cannot read data (expect 401).
set -euo pipefail
cd "$(dirname "$0")"

set -a; . ./.env; set +a
API="http://localhost:${POSTGREST_PORT:-3000}"
USER_NAME="${1:-user1}"

# Split a `curl -w $'\n%{http_code}'` response into $body / $code.
_code() { printf '%s' "$1" | tail -n1; }
_body() { printf '%s' "$1" | sed '$d'; }

echo "== 1. OpenAPI spec (no token) @ ${API}/ =="
code="$(curl -s -o /dev/null -w '%{http_code}' "${API}/")"
echo "   spec HTTP ${code}  $([ "$code" = 200 ] && echo '(anon OpenAPI visibility OK)' || echo '(expected 200)')"

echo "== 2. Mint token for '${USER_NAME}' from the OIDC test issuer =="
TOKEN="$(deno run --allow-net --allow-read ../pgdocker/get_user_token.ts "${USER_NAME}" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "   failed to mint token" >&2; exit 1; }
echo "   got token (${#TOKEN} chars)"

echo "== 3. POST /rpc/get_userinfo WITH token (JWT -> your identity + RBAC) =="
resp="$(curl -s -w $'\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}' \
  "${API}/rpc/get_userinfo")"
code="$(_code "$resp")"
echo "   HTTP ${code}  $([ "$code" != 401 ] && echo '(JWT path OK)' || echo '(unexpected 401)')"
echo "   data: $(_body "$resp" | cut -c1-150)..."

echo "== 4. GET /users WITH token (real rows via RLS) =="
resp="$(curl -s -w $'\n%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
  "${API}/users?select=id,email,display_name&limit=3")"
echo "   HTTP $(_code "$resp")  rows: $(_body "$resp")"

echo "== 5. GET /users WITHOUT token (expect 401 — anon cannot read data) =="
code="$(curl -s -o /dev/null -w '%{http_code}' "${API}/users?limit=1")"
echo "   /users (anon) HTTP ${code}  $([ "$code" = 401 ] && echo '(locked down OK)' || echo '(expected 401)')"

echo
echo "Done. Expected: spec 200; get_userinfo(auth) 200 + data; /users(auth) 200 + rows; /users(anon) 401."
