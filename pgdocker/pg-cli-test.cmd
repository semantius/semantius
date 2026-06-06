@echo off
REM Run the OAuth checks against the running container (needs Deno on PATH):
REM   verify_oauth.ts        - server validates the token + publishes the claims
REM   test_oauth_security.ts - a hostile client cannot impersonate (needs _core deployed)
cd /d "%~dp0"

echo == verify_oauth.ts ==
deno run --allow-net verify_oauth.ts || goto :err
echo.
echo == test_oauth_security.ts ==
deno run --allow-net test_oauth_security.ts || goto :err

exit /b 0

:err
echo.
echo Check failed. Is the container running (pg-cli-start.cmd) and _core deployed?

exit /b 1
