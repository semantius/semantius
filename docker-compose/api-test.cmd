@echo off
REM Smoke-test the running PostgREST stack (needs curl; steps 2-4 need Deno).
REM The core flow: mint a JWT from the test issuer, then read real data with it.
REM   1. OpenAPI spec at / without a token   (anon spec visibility)
REM   2. mint a token from the issuer (..\pgdocker\get_user_token.ts)
REM   3. RPC with the token (identity + RBAC)   4. table rows with the token
REM   5. table without a token (expect 401)
REM Ports are the .env defaults (3000); edit here if you changed POSTGREST_PORT.
cd /d "%~dp0"

set USER_NAME=%1
if "%USER_NAME%"=="" set USER_NAME=user1

echo == 1. OpenAPI spec (no token) @ http://localhost:3000/ ==
curl -s -o NUL -w "   spec HTTP %%{http_code}\n" http://localhost:3000/

echo == 2. Mint token for '%USER_NAME%' ==
for /f "delims=" %%T in ('deno run --allow-net --allow-read ..\pgdocker\get_user_token.ts %USER_NAME% 2^>NUL') do set TOKEN=%%T
if "%TOKEN%"=="" (
  echo    failed to mint token
  goto :err
)
echo    got token

echo == 3. POST /rpc/get_userinfo WITH token (JWT -^> identity + RBAC) ==
curl -s -X POST -H "Authorization: Bearer %TOKEN%" -H "Content-Type: application/json" -d "{}" -w "\n   HTTP %%{http_code}\n" http://localhost:3000/rpc/get_userinfo

echo == 4. GET /users WITH token (real rows via RLS) ==
curl -s -H "Authorization: Bearer %TOKEN%" -w "\n   HTTP %%{http_code}\n" "http://localhost:3000/users?select=id,email,display_name&limit=3"

echo == 5. GET /users WITHOUT token (expect 401) ==
curl -s -o NUL -w "   users(anon) HTTP %%{http_code}\n" "http://localhost:3000/users?limit=1"

echo.
echo Done. Expected: spec 200; get_userinfo(auth) 200 + data; users(auth) 200 + rows; users(anon) 401.
exit /b 0

:err
echo.
echo Test failed. Is the stack running (.\start.cmd)?
exit /b 1
