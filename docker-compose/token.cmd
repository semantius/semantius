@echo off
REM Mint a JWT for a test user and print it, to paste into the Scalar docs
REM "Authentication" box or use with curl.
REM   token.cmd            (default user1)
REM   token.cmd user2
REM Test-issuer users: user1 (John Smith), user2 (Maria Garcia), user3 (Wei Chen).
cd /d "%~dp0"

set USER_NAME=%1
if "%USER_NAME%"=="" set USER_NAME=user1

for /f "delims=" %%T in ('deno run --allow-net --allow-read ..\pgdocker\get_user_token.ts %USER_NAME% 2^>NUL') do set TOKEN=%%T
if "%TOKEN%"=="" (
  echo Failed to mint a token. Is deno installed and the issuer reachable?
  exit /b 1
)

echo %TOKEN%
echo.
echo Use it:
echo   - Scalar docs ^(http://localhost:8080^) -^> Authentication -^> JWT -^> paste:  Bearer ^<token^>
echo   - curl:  curl -H "Authorization: Bearer ^<token^>" http://localhost:3100/users
exit /b 0
