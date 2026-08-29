#!/usr/bin/env bash
# Smoke-test the running PostgREST stack (needs curl; steps 3-5 need Deno).
# The core flow: mint a JWT from the test issuer, then read real data with it.
#   1. Check the Caddy front door: SPA, runtime config, /rest/, /api-docs/.
#   2. GET the OpenAPI spec at / WITHOUT a token  -> proves anon spec visibility.
#   3. Mint a token for a test user from the issuer (reuses ../pgdocker/get_user_token.ts).
#   4. POST an RPC WITH the token   -> JWKS verify + SET ROLE authenticated + rbac.uid(); shows identity.
#   5. GET a table WITH the token   -> real rows via RLS.
#   6. GET a table WITHOUT a token  -> anon cannot read data (expect 401).
set -euo pipefail
cd "$(dirname "$0")"

set -a; . ./.env; set +a
WEB="http://localhost:${WEB_PORT:-3000}"
API="http://localhost:${POSTGREST_PORT:-3100}"
USER_NAME="${1:-user1}"

# Split a `curl -w $'\n%{http_code}'` response into $body / $code.
_code() { printf '%s' "$1" | tail -n1; }
_body() { printf '%s' "$1" | sed '$d'; }
_status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

echo "== 1. Front door (caddy) @ ${WEB} =="
code="$(_status "${WEB}/")"
echo "   /              HTTP ${code}  $([ "$code" = 200 ] && echo '(SPA served)' || echo '(expected 200)')"

# The SPA's runtime config, generated into config.js at container start. The
# control plane is opt-OUT and an EMPTY value still activates it, so the compose
# passes a single SPACE — if that is missing the app boots against the cloud
# control plane (api.semantius.cloud) and dies with a tenant-lookup error.
cfg="$(curl -s "${WEB}/config.js" || true)"
if printf '%s' "$cfg" | grep -Eq '"?VITE_CONTROL_PLANE_URL"?[[:space:]]*:[[:space:]]*"[[:space:]]+"'; then
  echo "   /config.js     self-hosted OK (VITE_CONTROL_PLANE_URL is whitespace)"
else
  echo "   /config.js     WARNING: VITE_CONTROL_PLANE_URL is not a whitespace value —"
  echo "                 the SPA will call the CLOUD control plane and fail to boot."
  echo "                 See the web service's env in docker-compose.yml."
fi

code="$(_status "${WEB}/rest/")"
echo "   /rest/         HTTP ${code}  $([ "$code" = 200 ] && echo '(spec through the front door)' || echo '(expected 200)')"
code="$(_status "${WEB}/gateway/rest/")"
echo "   /gateway/rest/ HTTP ${code}  $([ "$code" = 200 ] && echo '(spec through the idp gateway)' || echo '(expected 200)')"
code="$(_status "${WEB}/api-docs/")"
echo "   /api-docs/     HTTP ${code}  $([ "$code" = 200 ] && echo '(Scalar docs)' || echo '(expected 200)')"

echo "== 2. OpenAPI spec (no token) @ ${API}/ =="
code="$(_status "${API}/")"
echo "   spec HTTP ${code}  $([ "$code" = 200 ] && echo '(anon OpenAPI visibility OK)' || echo '(expected 200)')"

echo "== 3. Mint token for '${USER_NAME}' from the OIDC test issuer =="
TOKEN="$(deno run --allow-net --allow-read ../pgdocker/get_user_token.ts "${USER_NAME}" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "   failed to mint token" >&2; exit 1; }
echo "   got token (${#TOKEN} chars)"

echo "== 4. POST /rpc/get_userinfo WITH token (JWT -> your identity + RBAC) =="
resp="$(curl -s -w $'\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}' \
  "${API}/rpc/get_userinfo")"
code="$(_code "$resp")"
echo "   HTTP ${code}  $([ "$code" != 401 ] && echo '(JWT path OK)' || echo '(unexpected 401)')"
echo "   data: $(_body "$resp" | cut -c1-150)..."

echo "== 5. GET /users WITH token (real rows via RLS) =="
resp="$(curl -s -w $'\n%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
  "${API}/users?select=id,email,display_name&limit=3")"
echo "   HTTP $(_code "$resp")  rows: $(_body "$resp")"

echo "== 6. GET /users WITHOUT token (expect 401 — anon cannot read data) =="
code="$(_status "${API}/users?limit=1")"
echo "   /users (anon) HTTP ${code}  $([ "$code" = 401 ] && echo '(locked down OK)' || echo '(expected 401)')"

echo
echo "Done. Expected: front door / + /rest/ + /gateway/rest/ + /api-docs/ 200 and a whitespace"
echo "VITE_CONTROL_PLANE_URL; spec 200; get_userinfo(auth) 200 + data;"
echo "/users(auth) 200 + rows; /users(anon) 401."
