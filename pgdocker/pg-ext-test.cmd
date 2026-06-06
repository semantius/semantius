@echo off
REM Run the OAuth checks against the running EXTENSION container (needs Deno on
REM PATH). The extension installs _core, so rbac.uid() exists. Targets the
REM extension stack's port (5433):
REM   verify_oauth.ts        - server validates the token + publishes the claims
REM   test_oauth_security.ts - a hostile client cannot impersonate
cd /d "%~dp0"

echo == verify_oauth.ts (port 5433) ==
deno run --allow-net verify_oauth.ts --port 5433 || goto :err
echo.
echo == test_oauth_security.ts (port 5433) ==
deno run --allow-net test_oauth_security.ts --port 5433 || goto :err

exit /b 0

:err
echo.
echo Check failed. Is the container running (pg-ext-start.cmd) and the extension installed?

exit /b 1
