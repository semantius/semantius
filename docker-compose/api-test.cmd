@echo off
REM Smoke-test the running PostgREST stack (needs curl; steps 3-5 need Deno).
REM The core flow: mint a JWT from the test issuer, then read real data with it.
REM   1. the Caddy front door: SPA, runtime config, /api/, /api-docs/
REM   2. OpenAPI spec at / without a token   (anon spec visibility)
REM   3. mint a token from the issuer (..\pgdocker\get_user_token.ts)
REM   4. RPC with the token (identity + RBAC)   5. table rows with the token
REM   6. table without a token (expect 401)
REM Ports are the .env defaults (3000 front door, 3100 API); edit here if you
REM changed WEB_PORT / POSTGREST_PORT.
cd /d "%~dp0"

set USER_NAME=%1
if "%USER_NAME%"=="" set USER_NAME=user1

echo == 1. Front door (caddy) @ http://localhost:3000 ==
curl -s -o NUL -w "   /          HTTP %%{http_code}  (SPA)\n" http://localhost:3000/
REM The SPA's runtime config, generated into config.js at container start. The
REM control plane is opt-OUT and an EMPTY value still activates it, so the compose
REM passes a single SPACE - the line below must show a whitespace value, otherwise
REM the app boots against the cloud control plane and dies on tenant lookup.
echo    /config.js control plane line (must be a whitespace value):
curl -s http://localhost:3000/config.js | findstr /C:"VITE_CONTROL_PLANE_URL"
if errorlevel 1 echo    WARNING: VITE_CONTROL_PLANE_URL not found in config.js
curl -s -o NUL -w "   /api/      HTTP %%{http_code}  (spec through the front door)\n" http://localhost:3000/api/
curl -s -o NUL -w "   /api-docs/ HTTP %%{http_code}  (Scalar docs)\n" http://localhost:3000/api-docs/

echo == 2. OpenAPI spec (no token) @ http://localhost:3100/ ==
curl -s -o NUL -w "   spec HTTP %%{http_code}\n" http://localhost:3100/

echo == 3. Mint token for '%USER_NAME%' ==
for /f "delims=" %%T in ('deno run --allow-net --allow-read ..\pgdocker\get_user_token.ts %USER_NAME% 2^>NUL') do set TOKEN=%%T
if "%TOKEN%"=="" (
  echo    failed to mint token
  goto :err
)
echo    got token

echo == 4. POST /rpc/get_userinfo WITH token (JWT -^> identity + RBAC) ==
curl -s -X POST -H "Authorization: Bearer %TOKEN%" -H "Content-Type: application/json" -d "{}" -w "\n   HTTP %%{http_code}\n" http://localhost:3100/rpc/get_userinfo

echo == 5. GET /users WITH token (real rows via RLS) ==
curl -s -H "Authorization: Bearer %TOKEN%" -w "\n   HTTP %%{http_code}\n" "http://localhost:3100/users?select=id,email,display_name&limit=3"

echo == 6. GET /users WITHOUT token (expect 401) ==
curl -s -o NUL -w "   users(anon) HTTP %%{http_code}\n" "http://localhost:3100/users?limit=1"

echo.
echo Done. Expected: front door / + /api/ + /api-docs/ 200 and a whitespace
echo VITE_CONTROL_PLANE_URL; spec 200; get_userinfo(auth) 200 + data;
echo users(auth) 200 + rows; users(anon) 401.
exit /b 0

:err
echo.
echo Test failed. Is the stack running (.\start.cmd)?
exit /b 1
